import Foundation
import AppKit
import PDFKit

/// On-disk persistence: history metadata (JSON), images (PNG), and temporary audio (m4a).
final class Storage {
    static let shared = Storage()

    let baseURL: URL
    let imagesURL: URL
    let audioBaseURL: URL
    private let itemsURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")

        let newBase = appSupport.appendingPathComponent("Klip", isDirectory: true)
        let oldBase = appSupport.appendingPathComponent("PastaClip", isDirectory: true)

        // Migration: if the old folder exists and the new one does not yet, move it whole (atomic rename).
        if fm.fileExists(atPath: oldBase.path), !fm.fileExists(atPath: newBase.path) {
            do { try fm.moveItem(at: oldBase, to: newBase) }
            catch { try? fm.copyItem(at: oldBase, to: newBase) }
        }

        baseURL = newBase
        imagesURL = baseURL.appendingPathComponent("images", isDirectory: true)
        audioBaseURL = baseURL.appendingPathComponent("audio", isDirectory: true)
        itemsURL = baseURL.appendingPathComponent("items.json")
        try? fm.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: audioBaseURL, withIntermediateDirectories: true)
        // Same as items.json (0600): the store contains personal data (text, voice, images).
        Self.restrict(baseURL.path, 0o700)
        Self.restrict(imagesURL.path, 0o700)
        Self.restrict(audioBaseURL.path, 0o700)
    }

    /// Restricts a file/folder to the owner (privacy consistent with items.json).
    static func restrict(_ path: String, _ perms: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: path)
    }

    // MARK: - History (metadata)

    /// Credential secrets are stored encrypted on disk (see CredentialCrypto). Decrypt them back to
    /// plaintext for in-memory use; non-credential text and never-encrypted (legacy) text pass through.
    func decryptCredentials(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.map { item in
            if item.isCredential == true, let t = item.text, CredentialCrypto.isSealed(t) {
                // CRITICAL: if open() fails (key from another Mac / Keychain reset), KEEP the sealed token.
                // Nil'ing it would let the next saveItems write null over the only copy of the secret —
                // permanent data loss. With the token preserved, saveItems' isSealed guard round-trips it.
                guard let plain = CredentialCrypto.open(t) else { return item }
                var copy = item
                copy.text = plain
                return copy
            }
            // Promote legacy/never-flagged plaintext secrets (captured before this feature, or imported from
            // an old backup) so the next save seals them — otherwise they'd sit in items.json in the clear.
            // Uses the HIGH-CONFIDENCE detector: a silent at-rest encrypt+hide must not fire on a kebab/CSS
            // identifier or a prose "key: value" line.
            if item.kind == .text, item.isVoiceNote != true, item.isCredential != true,
               let t = item.text, !CredentialCrypto.isSealed(t), CredentialDetector.looksLikeHighConfidenceCredential(t) {
                var copy = item
                copy.isCredential = true
                copy.preview = CredentialDetector.maskedPlaceholder   // constant: never persist secret-derived chars
                return copy
            }
            return item
        }
    }

    /// Decodes items WITHOUT touching the Keychain (no credential decryption). Safe on the launch / main
    /// thread: a Keychain read here can raise a blocking "app wants to use your keychain" trust prompt that
    /// wedges the whole app before it ever runs. Decrypt separately, off the main thread (decryptCredentials).
    func loadItemsRaw() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: itemsURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let items = try? decoder.decode([ClipboardItem].self, from: data) { return items }
        // Decoding failed but the file exists → back it up before anything overwrites it.
        if !data.isEmpty {
            try? data.write(to: baseURL.appendingPathComponent("items.corrupt.json"), options: .atomic)
        }
        return []
    }

    /// Convenience: raw load + decrypt. Only call OFF the main thread (it touches the Keychain).
    func loadItems() -> [ClipboardItem] { decryptCredentials(loadItemsRaw()) }

    func saveItems(_ items: [ClipboardItem]) {
        // Encrypt credential secrets before they hit disk (and the backup zip). In-memory items are
        // untouched; if encryption is unavailable we keep the plaintext rather than lose the value.
        let toStore = items.map { item -> ClipboardItem in
            guard item.isCredential == true, let t = item.text, !t.isEmpty, !CredentialCrypto.isSealed(t) else { return item }
            guard let sealed = CredentialCrypto.seal(t) else {
                // Keychain key unreadable (e.g. the app was re-signed with a different identity and the user
                // denied the access prompt). We keep the value rather than lose it, but it would land in
                // cleartext — make that NON-SILENT so it can be diagnosed instead of degrading privacy quietly.
                NSLog("KLIP: could not encrypt a credential (Keychain key inaccessible); value kept unsealed")
                return item
            }
            var copy = item
            copy.text = sealed
            return copy
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(toStore) else { return }
        try? data.write(to: itemsURL, options: .atomic)
        // Defense in depth on top of the encryption: restrict the file to the user only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: itemsURL.path)
    }

    // MARK: - Images

    @discardableResult
    func saveImage(_ image: NSImage, fileName: String) -> URL? {
        guard let png = pngData(from: image) else { return nil }
        let url = imagesURL.appendingPathComponent(fileName)
        do {
            try png.write(to: url, options: .atomic)
            Self.restrict(url.path, 0o600)
            return url
        } catch { return nil }
    }

    func imageURL(for fileName: String) -> URL { imagesURL.appendingPathComponent(fileName) }
    func loadImage(fileName: String) -> NSImage? { NSImage(contentsOf: imageURL(for: fileName)) }

    /// Writes data straight to ~/Downloads with a collision-safe name — no save dialog
    /// (Shottr-style: saving should never ask for a name). `base` defaults to a timestamped
    /// "Klip <date> at <time>"; pass a clip's name to keep it. Returns the written URL.
    func exportToDownloads(_ data: Data, ext: String, base: String? = nil) throws -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let name: String
        if let base, !base.isEmpty {
            // Sanitize a user-provided clip name for the filesystem.
            name = base.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
        } else {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            name = "Klip \(df.string(from: Date()))"
        }
        var url = dir.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name)-\(n).\(ext)"); n += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Same timestamped, collision-safe Downloads export, but MOVING an existing file instead of
    /// writing a Data blob — a screen recording can be hundreds of MB and must never be loaded
    /// into memory just to relocate it.
    func exportFileToDownloads(from src: URL, ext: String, base: String? = nil) throws -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let name: String
        if let base, !base.isEmpty {
            name = base.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
        } else {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            name = "Klip \(df.string(from: Date()))"
        }
        var url = dir.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name)-\(n).\(ext)"); n += 1
        }
        try FileManager.default.moveItem(at: src, to: url)
        return url
    }

    func exportPNGToDownloads(_ png: Data) throws -> URL { try exportToDownloads(png, ext: "png") }

    func deleteImage(fileName: String) {
        imageCache.removeObject(forKey: fileName as NSString)
        try? FileManager.default.removeItem(at: imageURL(for: fileName))
    }

    private let imageCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>(); c.countLimit = 60; return c
    }()

    /// In-memory cached image: avoids re-reading/decoding from disk on every list render.
    func cachedImage(fileName: String) -> NSImage? {
        if let c = imageCache.object(forKey: fileName as NSString) { return c }
        guard let img = loadImage(fileName: fileName) else { return nil }
        imageCache.setObject(img, forKey: fileName as NSString)
        return img
    }

    func pngData(from image: NSImage) -> Data? {
        // If the image already has a bitmap, encode PNG directly from the highest-resolution rep
        // (avoids the round-trip through TIFF, which doubles memory for large captures).
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide < $1.pixelsWide }),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Audio (voice notes: the original is kept alongside the transcription)

    func audioURL(for fileName: String) -> URL { audioBaseURL.appendingPathComponent(fileName) }
    func deleteAudio(fileName: String) { try? FileManager.default.removeItem(at: audioURL(for: fileName)) }
    func audioExists(fileName: String) -> Bool { FileManager.default.fileExists(atPath: audioURL(for: fileName).path) }

    /// Restricts a voice note audio file to 0600 (AVAudioRecorder creates it with the default umask).
    func protectAudio(fileName: String) { Self.restrict(audioURL(for: fileName).path, 0o600) }

    /// Copies an external audio file (uploaded by the user) into our store and returns the new name,
    /// so it can be played and kept even if the original file is moved or deleted.
    func importAudio(from url: URL) -> String? {
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        let dest = audioURL(for: name)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            Self.restrict(dest.path, 0o600)
            return name
        } catch { return nil }
    }

    /// Deletes audio/image files no longer referenced by any item (orphaned by a crash, etc.).
    func pruneOrphans(referencedAudio: Set<String>, referencedImages: Set<String>) {
        prune(dir: audioBaseURL, keep: referencedAudio)
        prune(dir: imagesURL, keep: referencedImages)
    }

    private func prune(dir: URL, keep: Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where !keep.contains(name) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Backup (export / import)

    /// Exports the history (items.json + images + audio) to a .zip. Does NOT include the API keys.
    func exportBackup(to dest: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("KlipExport-\(UUID().uuidString)", isDirectory: true)
        let stage = work.appendingPathComponent("Klip", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        if fm.fileExists(atPath: itemsURL.path) {
            try fm.copyItem(at: itemsURL, to: stage.appendingPathComponent("items.json"))
        }
        if fm.fileExists(atPath: imagesURL.path) {
            try fm.copyItem(at: imagesURL, to: stage.appendingPathComponent("images"))
        }
        if fm.fileExists(atPath: audioBaseURL.path) {
            try fm.copyItem(at: audioBaseURL, to: stage.appendingPathComponent("audio"))
        }
        try? fm.removeItem(at: dest)
        try Self.runDitto(["-c", "-k", "--keepParent", stage.path, dest.path])
    }

    /// Imports a .zip backup and REPLACES the current history, **transactionally**:
    /// validates the backup, moves the current data to `.importbak`, copies the new data and, on ANY failure,
    /// restores from the backup → the existing history is never lost. Returns the items.
    /// (Heavy: run it off the main thread.)
    func importBackup(from src: URL) throws -> [ClipboardItem] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("KlipImport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try Self.runDitto(["-x", "-k", src.path, tmp.path])

        guard let root = Self.findBackupRoot(in: tmp) else {
            throw Self.err(L10n.t("backup.err.notBackup"))
        }
        // Validate that the backup's items.json decodes BEFORE touching anything (don't import garbage).
        let newItemsFile = root.appendingPathComponent("items.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: newItemsFile),
              let decoded = try? decoder.decode([ClipboardItem].self, from: data) else {
            throw Self.err(L10n.t("backup.err.corrupt"))
        }

        let newImages = root.appendingPathComponent("images")
        let newAudio = root.appendingPathComponent("audio")
        // Backups with a unique name per attempt → leftovers from an aborted import never collide
        // with the moveItem below (avoids restoring a stale .bak over the intact original).
        let token = UUID().uuidString
        let bakItems = baseURL.appendingPathComponent("items.json.\(token).importbak")
        let bakImages = baseURL.appendingPathComponent("images.\(token).importbak")
        let bakAudio = baseURL.appendingPathComponent("audio.\(token).importbak")
        // Clean up leftovers from earlier aborted imports — but NEVER this attempt's own backups (skip our
        // token), so an overlapping import can't delete the backup we're about to rely on for rollback.
        if let leftovers = try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) {
            for f in leftovers where f.lastPathComponent.hasSuffix(".importbak") && !f.lastPathComponent.contains(token) {
                try? fm.removeItem(at: f)
            }
        }

        // Restores a destination from its backup (only if the backup exists → original is safe).
        func restore(_ live: URL, _ bak: URL) {
            guard fm.fileExists(atPath: bak.path) else { return }   // no bak: the live copy is the intact original
            try? fm.removeItem(at: live)
            try? fm.moveItem(at: bak, to: live)
        }

        do {
            // Move the current data to .bak (atomic renames within the same volume).
            if fm.fileExists(atPath: itemsURL.path)     { try fm.moveItem(at: itemsURL, to: bakItems) }
            if fm.fileExists(atPath: imagesURL.path)    { try fm.moveItem(at: imagesURL, to: bakImages) }
            if fm.fileExists(atPath: audioBaseURL.path) { try fm.moveItem(at: audioBaseURL, to: bakAudio) }
            // Put the new data in place.
            try fm.copyItem(at: newItemsFile, to: itemsURL)
            if fm.fileExists(atPath: newImages.path) { try fm.copyItem(at: newImages, to: imagesURL) }
            else { try fm.createDirectory(at: imagesURL, withIntermediateDirectories: true) }
            if fm.fileExists(atPath: newAudio.path) { try fm.copyItem(at: newAudio, to: audioBaseURL) }
            else { try fm.createDirectory(at: audioBaseURL, withIntermediateDirectories: true) }
        } catch {
            restore(itemsURL, bakItems)        // rollback: leaves the history as it was
            restore(imagesURL, bakImages)
            restore(audioBaseURL, bakAudio)
            throw error
        }

        [bakItems, bakImages, bakAudio].forEach { try? fm.removeItem(at: $0) }   // success: clean up backups
        Self.restrict(itemsURL.path, 0o600)
        Self.restrict(imagesURL.path, 0o700)
        Self.restrict(audioBaseURL.path, 0o700)
        imageCache.removeAllObjects()
        let result = decryptCredentials(decoded)   // creds in the imported items.json are encrypted on disk
        // importBackup runs OFF the main thread. If any imported credential will need sealing on the next
        // save (a legacy plaintext secret just promoted), pre-create the Keychain key HERE so the on-main
        // reload→saveItems only READS it — never a Keychain WRITE on the main thread (avoids the hang class).
        if result.contains(where: { $0.isCredential == true && ($0.text.map { !CredentialCrypto.isSealed($0) } ?? false) }) {
            CredentialCrypto.warmKey()
        }
        return result
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "Klip", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// Locates the backup folder that contains items.json (keepParent → .../Klip/items.json).
    private static func findBackupRoot(in dir: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("items.json").path) { return dir }
        guard let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for sub in subs where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if fm.fileExists(atPath: sub.appendingPathComponent("items.json").path) { return sub }
        }
        return nil
    }

    private static func runDitto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Klip", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(format: L10n.t("backup.err.ditto"), p.terminationStatus)])
        }
    }

    // MARK: - Combine / export selection (vibe coders)

    /// Combines several items into a PDF (one page per item): images as an image page,
    /// text as a text page. For uploading several captures/notes to an AI all at once.
    /// Returns the data and how many pages were generated (may be fewer than items.count if some
    /// item had no exportable content). nil if no page could be generated.
    /// Text safe to write to an exported file/PDF: credentials are masked, never written in the clear
    /// (mirrors MarkdownExporter). Returns nil if there's no text to export.
    static func exportableText(_ item: ClipboardItem) -> String? {
        guard let t = item.text, !t.isEmpty else { return nil }
        // Use the chars-free placeholder (not masked(), which would leak the secret's real last 4 into a
        // shared PDF/ZIP/Markdown export).
        return item.isCredential == true ? CredentialDetector.maskedPlaceholder : t
    }

    func combinedPDF(from items: [ClipboardItem]) -> (data: Data, exported: Int)? {
        let doc = PDFDocument()
        var idx = 0
        for it in items {
            var pageImage: NSImage?
            if it.kind == .image, let f = it.imageFileName { pageImage = loadImage(fileName: f) }
            else if let t = Self.exportableText(it) { pageImage = Self.pageImage(forText: t) }
            if let img = pageImage, let page = PDFPage(image: img) { doc.insert(page, at: idx); idx += 1 }
        }
        guard idx > 0, let data = doc.dataRepresentation() else { return nil }
        return (data, idx)
    }

    /// Renders text into a "page" (letter-size image) with margins, to embed in the PDF.
    /// Uses a drawingHandler (thread-safe off the main thread) instead of lockFocus, since combinedPDF
    /// runs on a background queue.
    private static func pageImage(forText text: String) -> NSImage {
        let pageW: CGFloat = 612, margin: CGFloat = 40   // US Letter at 72 dpi
        let style = NSMutableParagraphStyle(); style.lineSpacing = 3
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.black, .paragraphStyle: style]
        let textW = pageW - margin * 2
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: textW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        let pageH = max(200, ceil(bounds.height) + margin * 2)
        return NSImage(size: NSSize(width: pageW, height: pageH), flipped: false) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: pageW, height: pageH).fill()
            (text as NSString).draw(with: NSRect(x: margin, y: margin, width: textW, height: pageH - margin * 2),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
            return true
        }
    }

    /// How many of the items have content to export to ZIP (image on disk, audio, or text).
    func zipExportableCount(_ items: [ClipboardItem]) -> Int {
        let fm = FileManager.default
        return items.reduce(0) { acc, it in
            if it.kind == .image, let f = it.imageFileName, fm.fileExists(atPath: imageURL(for: f).path) { return acc + 1 }
            if let af = it.audioFileName, audioExists(fileName: af) { return acc + 1 }
            if let t = it.text, !t.isEmpty { return acc + 1 }
            return acc
        }
    }

    /// Exports the selected items to a .zip (PNG images, .txt text, audio). For uploading the batch together.
    func exportItemsZip(_ items: [ClipboardItem], to dest: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("KlipSel-\(UUID().uuidString)", isDirectory: true)
        let stage = work.appendingPathComponent("Klip", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        for (i, it) in items.enumerated() {
            let n = String(format: "%02d", i + 1)
            let base = (it.name?.isEmpty == false ? it.name! : "item").replacingOccurrences(of: "/", with: "-")
            if it.kind == .image, let f = it.imageFileName, fm.fileExists(atPath: imageURL(for: f).path) {
                try? fm.copyItem(at: imageURL(for: f), to: stage.appendingPathComponent("\(n)-\(base).png"))
            } else if let af = it.audioFileName, audioExists(fileName: af) {
                try? fm.copyItem(at: audioURL(for: af), to: stage.appendingPathComponent("\(n)-\(base).m4a"))
                if let t = Self.exportableText(it) { try? t.data(using: .utf8)?.write(to: stage.appendingPathComponent("\(n)-\(base).txt")) }
            } else if let t = Self.exportableText(it) {
                try? t.data(using: .utf8)?.write(to: stage.appendingPathComponent("\(n)-\(base).txt"))
            }
        }
        try? fm.removeItem(at: dest)
        try Self.runDitto(["-c", "-k", "--keepParent", stage.path, dest.path])
    }
}

extension NSImage {
    /// REAL dimensions in pixels (not points): takes the highest-resolution rep. On retina
    /// displays, `size` comes in points (half), so this is what the user expects to see.
    var pixelDimensions: NSSize {
        var w = 0, h = 0
        for r in representations { w = max(w, r.pixelsWide); h = max(h, r.pixelsHigh) }
        return (w > 0 && h > 0) ? NSSize(width: w, height: h) : size
    }
}

import AppKit

/// Orchestrates the "Klip Snap" capture flow: permission → capture the display under the cursor →
/// selection overlay → annotation editor → Klip history.
final class SnapController {
    private let manager: ClipboardManager
    private var overlay: CaptureOverlayController?
    private var editor: SnapEditorController?
    private var inProgress = false

    /// Invoked after adding a capture to the history (to reveal the panel: the item "flies" to Klip).
    var onCaptured: (() -> Void)?

    /// What to do with the selected region: open the annotation editor, or OCR it straight to the clipboard.
    enum Mode { case annotate, text }

    init(manager: ClipboardManager) {
        self.manager = manager
        ScreenCapturer.warmUp()
    }

    /// Entry point (shortcut or menu): capture a region and open the annotation editor.
    func start() { begin(mode: .annotate) }

    /// Entry point: capture a region and extract its text (OCR) straight to the clipboard — no editor.
    func startTextCapture() { begin(mode: .text) }

    private func begin(mode: Mode) {
        // Block re-entry for the WHOLE flow: while capturing (inProgress) and while the selection overlay
        // or the editor is on screen. Otherwise a second trigger would stack shield windows and leak the first.
        guard !inProgress, overlay == nil, editor == nil else { return }

        guard ScreenCapturer.hasPermission() else {
            promptForPermission()
            return
        }

        inProgress = true
        let mouse = NSEvent.mouseLocation
        Task { @MainActor in
            do {
                let shot = try await ScreenCapturer.captureDisplay(containing: mouse)
                self.inProgress = false
                self.presentOverlay(shot, mode: mode)
            } catch CaptureError.noPermission {
                self.inProgress = false          // release BEFORE the modal (avoids runloop reentrancy)
                self.promptForPermission()
            } catch {
                self.inProgress = false
                SoundFX.error()
                ToastHUD.show(L10n.t("capture.failed"), style: .failure)
            }
        }
    }

    @MainActor
    private func presentOverlay(_ shot: DisplayShot, mode: Mode) {
        let overlay = CaptureOverlayController(shot: shot) { [weak self] image in
            self?.overlay = nil
            guard let self, let image else { return }
            switch mode {
            case .annotate:
                // Post-capture destination (Shottr-style): "clipboard" skips the annotation editor
                // entirely — the region goes straight to history + clipboard.
                if Settings.shared.captureDestination == "clipboard" {
                    self.manager.addAnnotatedScreenshot(image)
                    ToastHUD.show(L10n.t("toast.copied"))
                    self.onCaptured?()
                } else {
                    SoundFX.play(.pop)   // region captured → editor opening
                    self.openEditor(with: image)
                }
            case .text:     self.extractText(from: image)
            }
        }
        self.overlay = overlay
        overlay.present()
    }

    /// OCR the selected region OFF the main thread, then put the text on the clipboard + into history.
    @MainActor
    private func extractText(from image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { SoundFX.error(); return }
        Task { @MainActor [weak self] in
            let text = await Task.detached { OCR.recognizeText(in: cg) }.value   // OCR off the main thread
            guard let self else { return }
            guard self.manager.addCapturedText(text) else {   // nothing recognized: say so — a bare beep
                SoundFX.error()                                   // can't be told apart from "the feature broke"
                ToastHUD.show(L10n.t("snap.notext.title"), detail: L10n.t("snap.notext.info"), style: .failure)
                return
            }
            ToastHUD.show(L10n.t("toast.textCopied"), detail: text,
                          actionTitle: L10n.t("toast.removeLineBreaks")) { [weak self] in
                guard let self else { return }
                // Re-copy through the same manager path so the cleaned text also lands in history.
                self.manager.addCapturedText(Self.collapsingHardWraps(text))
                ToastHUD.show(L10n.t("toast.copied"))
            }
            self.onCaptured?()
        }
    }

    /// Collapses OCR hard-wrapping: a lone newline becomes a space; runs of 2+ newlines
    /// (paragraph breaks) are kept as-is.
    static func collapsingHardWraps(_ text: String) -> String {
        text.replacingOccurrences(of: "(?<!\\n)\\n(?!\\n)", with: " ", options: .regularExpression)
    }

    @MainActor
    private func openEditor(with image: NSImage) {
        let editor = SnapEditorController(image: image) { [weak self] result in
            self?.editor = nil
            guard let self, let result else { return }   // nil = closed without saving
            self.manager.addAnnotatedScreenshot(result, copyToClipboard: true)
            self.onCaptured?()
        }
        self.editor = editor
        editor.present()
    }

    /// No Screen Recording permission. The FIRST time we only show the native system prompt
    /// (`requestPermission`); on later attempts (when the native prompt no longer reappears) we show
    /// our own guide with a shortcut to Settings. This way the two messages never overlap.
    private func promptForPermission() {
        let askedKey = "klip.askedScreenRecording"
        if !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            ScreenCapturer.requestPermission()   // only the native prompt the first time
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.t("perm.screen.title")
        alert.informativeText = L10n.t("perm.screen.info")
        alert.addButton(withTitle: L10n.t("perm.screen.open"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Floating panel that can receive keyboard focus without becoming the main window.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Controls the history popup window: HUD vibrancy, contextual positioning,
/// animated appearance, keyboard navigation, close on outside click, auto-paste, voice, and Markdown.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: KeyablePanel!
    private var effectView: NSVisualEffectView!
    private let manager: ClipboardManager
    private let selection = SelectionModel()
    private let recorder = Recorder()
    /// True while recording, finishing, or transcribing audio — used to block a destructive import.
    var isBusyWithAudio: Bool { recorder.isRecording || recorder.finishing || recorder.transcribingCount > 0 }
    /// True while one of our auxiliary windows is on screen, so the panel's auto-hide on
    /// outside click / resign-key doesn't fire while the user interacts with one of them (Upload/Guide/Welcome/Recording).
    private var auxWindowVisible: Bool {
        [uploadWindow, guideWindow, welcomeWindow, recordingPanel].contains { $0?.isVisible == true }
    }
    private weak var statusItem: NSStatusItem?
    private weak var previousApp: NSRunningApplication?

    /// Injected by AppDelegate to open Preferences from the panel (missing-API-key state).
    var onOpenPreferences: (() -> Void)?
    /// Injected by AppDelegate to trigger the new Klip Snap from the panel's camera button.
    var onCaptureAnnotate: (() -> Void)?

    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    /// Number of active modal panels (save/open). While > 0 the panel doesn't close on losing
    /// focus. It's a counter (not a bool) so two overlapping panels don't stomp on each other's state.
    private var modalCount = 0
    private var isModalActive: Bool { modalCount > 0 }
    /// Prevents launching a second export (PDF/ZIP) while one is in flight.
    private var exportInFlight = false
    private var isRenaming = false
    private let cornerRadius: CGFloat = 12
    private var recordingPanel: NSPanel?
    private var guideWindow: NSWindow?
    private var uploadWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    init(manager: ClipboardManager, statusItem: NSStatusItem?) {
        self.manager = manager
        self.statusItem = statusItem
        super.init()
        buildPanel()
    }

    private func buildPanel() {
        recorder.onVoiceNoteStarted = { [weak self] fn, dur, autoCopy in self?.manager.beginVoiceNote(audioFileName: fn, duration: dur, allowAutoCopy: autoCopy) }
        recorder.onVoiceNoteTranscribed = { [weak self] id, text in self?.manager.finishVoiceNote(id: id, text: text) }
        recorder.onVoiceNoteDuration = { [weak self] id, dur in self?.manager.setVoiceNoteDuration(id: id, duration: dur) }
        recorder.onVoiceNoteFailed = { [weak self] id in self?.manager.failVoiceNote(id: id) }
        recorder.onVoiceNoteRetrying = { [weak self] id in self?.manager.markVoiceNoteTranscribing(id: id) }
        recorder.onVoiceNoteDownloadingModel = { [weak self] id in self?.manager.markVoiceNoteDownloadingModel(id: id) }
        recorder.onVoiceNoteAudioStored = { [weak self] id, fn in self?.manager.setVoiceNoteAudioFile(id: id, fileName: fn) }

        let root = HistoryView(
            manager: manager,
            selection: selection,
            recorder: recorder,
            onPick: { [weak self] item in self?.pick(item) },
            onSaveImage: { [weak self] item in self?.saveImage(item) },
            onCopyMarkdown: { [weak self] item in self?.copyMarkdown(of: item) },
            onCopyAllMarkdown: { [weak self] in self?.copyAllMarkdown() },
            onOpenPreferences: { [weak self] in self?.hide(restoreFocus: false); self?.onOpenPreferences?() },
            onUploadAudio: { [weak self] in self?.uploadAudio() },
            onVoiceRecord: { [weak self] in self?.toggleVoiceRecording() },
            onShowGuide: { [weak self] in self?.showGuide() },
            onRename: { [weak self] item in self?.renameItem(item) },
            onDelete: { [weak self] item in self?.confirmDelete(item) },
            onRetryTranscription: { [weak self] item in self?.retryTranscription(item) },
            onSaveAsFile: { [weak self] item in self?.saveTextAsFile(item) },
            onCopyAsCode: { [weak self] item in self?.copyAsCode(of: item) },
            onCaptureAnnotate: { [weak self] in self?.onCaptureAnnotate?() },
            onCombinePDF: { [weak self] items in self?.combineSelectedToPDF(items) },
            onExportZip: { [weak self] items in self?.exportSelectedZip(items) },
            onAssignCollection: { [weak self] items in self?.assignSelectedToCollection(items) }
        )

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        // Appear in the CURRENT Space and ABOVE full-screen apps. Without this, pressing the shortcut while a
        // full-screen app (e.g. an IDE) has focus triggers the action but the panel opens in another Space —
        // it looks like "nothing happened". fullScreenAuxiliary lets it overlay the full-screen Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 480, height: 640))
        fx.material = .menu
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.masksToBounds = true
        fx.autoresizingMask = [.width, .height]
        self.effectView = fx

        let hosting = NSHostingView(rootView: root)
        hosting.frame = fx.bounds
        hosting.autoresizingMask = [.width, .height]
        fx.addSubview(hosting)

        panel.contentView = fx
        self.panel = panel
    }

    func toggle() {
        if isModalActive { return }   // don't open/close the panel while a save/export sheet is open behind it
        panel.isVisible ? hide() : show()
    }

    func show() {
        guard !panel.isVisible else { return }   // idempotent: avoids reinstalling the monitors
        previousApp = NSWorkspace.shared.frontmostApplication
        positionPanel()

        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()   // force it to the front even when Klip isn't the active app (e.g. over a full-screen IDE)
        selection.reset()
        selection.selecting = false               // authoritative on open (don't rely on SwiftUI onChange timing)
        selection.openToken &+= 1                 // triggers the search/focus reset in the view
        if recordingPanel?.isVisible != true { recorder.reset() }  // don't close the voice popup if it's open

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        installMonitors()
    }

    func hide(restoreFocus: Bool = true) {
        removeMonitors()
        AudioPlayer.shared.stop()   // don't leave audio playing when the panel closes
        panel.orderOut(nil)
        if restoreFocus { previousApp?.activate() }
    }

    // MARK: - Monitors (keyboard + outside click)

    private func installMonitors() {
        removeMonitors()   // never leave orphaned monitors
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { e in e }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isModalActive, !self.isRenaming, !self.recorder.isRecording,
                  !self.auxWindowVisible else { return }   // don't close while a child window is on screen
            self.hide(restoreFocus: false)
        }
    }

    private func removeMonitors() {
        [keyMonitor, localClickMonitor, globalClickMonitor].forEach {
            if let m = $0 { NSEvent.removeMonitor(m) }
        }
        keyMonitor = nil; localClickMonitor = nil; globalClickMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if isRenaming { return event }   // the rename dialog handles its own keys
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53 {   // Esc (the monitor always runs on the main thread)
            if recorder.finishing {
                return nil   // a stop is finalizing: let it finish — don't cancel (that would delete the note)
            } else if recorder.state == .recording {
                // Long recordings are real work: route Esc to the popup's own confirm instead of nuking
                // >10s of dictation from a different surface (the popup shows the Discard? guard).
                if MainActor.assumeIsolated({ recorder.duration }) > 10 { return nil }
                MainActor.assumeIsolated { recorder.cancel() }   // aborts the recording, doesn't close
            } else if !recorder.isRecording {                    // don't close while transcribing
                // Layered back-out: exit multi-select first, then clear the search, then close.
                if selection.selecting {
                    selection.selecting = false      // HistoryView observes this and drops the batch
                } else if selection.searchHasText {
                    selection.clearSearchToken &+= 1 // HistoryView clears the search field
                } else {
                    hide(restoreFocus: true)
                }
            }
            return nil
        }

        // In batch multi-select mode the keyboard does NOT paste/close (it would break the batch in progress):
        // arrows only navigate; ⌘1-9 / Return don't pick. The mouse still toggles (onToggleCheck).
        // Batch mode (multi-select) is driven by the mouse (checkboxes). Don't move a keyboard cursor here
        // with no visible highlight — it only confused; let the keys pass through (search typing, list scrolling).
        if selection.selecting { return event }

        // ⌘↩ → copies the selected text item as a code block (the vibe-coder's star action), keyboard only.
        if flags == .command, event.keyCode == 36,
           let id = selection.selectedID, let item = manager.items.first(where: { $0.id == id }),
           item.kind == .text, item.isCredential != true, !(item.text?.isEmpty ?? true) {   // never auto-paste a secret
            copyAsCode(of: item); return nil
        }
        // ⌘⌫ → delete the selected item (confirming first if it has media, like the row's menu).
        // Deferred: don't start a modal alert loop inside the event-monitor callback.
        if flags == .command, event.keyCode == 51,
           let id = selection.selectedID, let item = manager.items.first(where: { $0.id == id }) {
            DispatchQueue.main.async { [weak self] in self?.confirmDelete(item) }
            return nil
        }
        // ⌘⇧F → toggle favorite (star) on the selected item.
        if flags == [.command, .shift], event.keyCode == 3,
           let id = selection.selectedID, let item = manager.items.first(where: { $0.id == id }) {
            manager.togglePin(item); return nil
        }
        if flags.contains(.command) { return event }   // don't break ⌘A/⌘C/⌘V in the search field

        switch event.keyCode {
        case 125: selection.moveDown(); return nil    // ↓
        case 126: selection.moveUp();   return nil    // ↑
        case 36, 76: pickSelected();    return nil    // Return / Enter
        default: return event
        }
    }

    // MARK: - Positioning

    private func positionPanel() {
        let size = panel.frame.size
        let gap: CGFloat = 6
        if let btnWin = statusItem?.button?.window {
            let b = btnWin.frame
            let screen = btnWin.screen ?? NSScreen.main ?? NSScreen.screens.first!
            panel.setFrameOrigin(clamp(x: b.midX - size.width / 2,
                                       y: b.minY - gap - size.height, size: size, into: screen.visibleFrame))
        } else {
            let m = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(m) }
                ?? NSScreen.main ?? NSScreen.screens.first!
            panel.setFrameOrigin(clamp(x: m.x - size.width / 2,
                                       y: m.y - size.height - gap, size: size, into: screen.visibleFrame))
        }
    }

    private func clamp(x: CGFloat, y: CGFloat, size: NSSize, into vf: NSRect) -> NSPoint {
        let hiX = max(vf.minX + 8, vf.maxX - size.width - 8)   // guarantees lo <= hi on small screens
        let hiY = max(vf.minY + 8, vf.maxY - size.height - 8)
        let cx = min(max(x, vf.minX + 8), hiX)
        let cy = min(max(y, vf.minY + 8), hiY)
        return NSPoint(x: cx, y: cy)
    }

    // MARK: - Actions

    private func pick(_ item: ClipboardItem) {
        // Voice note without a transcription: no text to paste → play the audio and leave the panel open.
        if item.kind == .text, (item.text?.isEmpty ?? true) {
            if let af = item.audioFileName { AudioPlayer.shared.toggle(fileName: af) }
            return
        }
        manager.copyToPasteboard(item)
        let target = previousApp
        hide(restoreFocus: false)
        if item.isCredential == true { target?.activate() }   // don't auto-paste secrets: just copy + restore focus
        else { pasteOrRestore(target) }
    }

    private func pickSelected() {
        guard let id = selection.selectedID,
              let item = manager.items.first(where: { $0.id == id }) else { return }
        pick(item)
    }

    /// Auto-pastes into the previous app (given permission and a target app), or just restores focus.
    private func pasteOrRestore(_ target: NSRunningApplication?) {
        guard let target, !target.isTerminated else { return }   // no target: it simply stays copied
        if Settings.shared.autoPaste { Paster.paste(into: target) }
        else { target.activate() }
    }

    private func copyMarkdown(of item: ClipboardItem) {
        guard item.isCredential != true else { return }   // never auto-paste a secret as Markdown
        let md = Markdownify.fromText(item.text ?? "")
        let target = previousApp
        manager.setClipboardText(md)
        hide(restoreFocus: false)
        pasteOrRestore(target)
    }

    private func copyAllMarkdown() {
        let md = MarkdownExporter.history(manager.items)
        let target = previousApp
        manager.setClipboardText(md)
        hide(restoreFocus: false)
        pasteOrRestore(target)
    }

    /// Copies the text wrapped in a Markdown code block (``` ```), ready to paste into an AI chat.
    private func copyAsCode(of item: ClipboardItem) {
        guard item.isCredential != true else { return }   // never wrap+auto-paste a secret
        guard let t = item.text, !t.isEmpty else { return }
        let target = previousApp
        manager.setClipboardText("```\(Markdownify.inferCodeLanguage(t))\n\(t)\n```")
        hide(restoreFocus: false)
        pasteOrRestore(target)
    }

    /// Saves the item's text as a file (.txt/.md) so it can be dragged into an AI tool
    /// when the chat won't accept pasting it (very large texts/logs).
    private func saveTextAsFile(_ item: ClipboardItem) {
        guard item.isCredential != true else { return }   // don't write a secret to a plain-text file
        guard let t = item.text, !t.isEmpty else { return }
        let sp = NSSavePanel()
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        sp.allowedContentTypes = types
        sp.nameFieldStringValue = (item.name?.isEmpty == false ? item.name! : "klip-text") + ".txt"
        sp.canCreateDirectories = true
        modalCount += 1   // "a modal panel is open" guard (don't close the panel behind it)
        NSApp.activate(ignoringOtherApps: true)
        sp.begin { [weak self] resp in
            if resp == .OK, let url = sp.url { try? t.data(using: .utf8)?.write(to: url, options: .atomic) }
            self?.modalCount -= 1
        }
    }

    // MARK: - Combine / export selection

    func combineSelectedToPDF(_ items: [ClipboardItem]) {
        guard !items.isEmpty, !exportInFlight else { return }   // don't overlap exports
        exportInFlight = true
        modalCount += 1   // protects the panel through the whole generation + save (closes the race window)
        manager.pauseMonitoring()   // keeps the poll's trim from deleting selected media mid-generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Storage.shared.combinedPDF(from: items)
            DispatchQueue.main.async {
                guard let self else { return }
                self.manager.resumeMonitoring()   // the media reads are done
                guard let result else {   // nothing exportable: warn instead of "the button does nothing"
                    self.modalCount -= 1; self.exportInFlight = false
                    self.showAlert(L10n.t("export.empty.title"), L10n.t("export.empty.info"))
                    return
                }
                let sp = NSSavePanel()
                sp.allowedContentTypes = [.pdf]
                sp.nameFieldStringValue = "klip.pdf"
                sp.canCreateDirectories = true
                if result.exported < items.count {
                    sp.message = String(format: L10n.t("export.partial"), result.exported, items.count)
                }
                NSApp.activate(ignoringOtherApps: true)
                sp.begin { resp in
                    if resp == .OK, let url = sp.url { try? result.data.write(to: url, options: .atomic) }
                    self.modalCount -= 1; self.exportInFlight = false
                }
            }
        }
    }

    func exportSelectedZip(_ items: [ClipboardItem]) {
        guard !items.isEmpty, !exportInFlight else { return }
        let exportable = Storage.shared.zipExportableCount(items)
        guard exportable > 0 else { showAlert(L10n.t("export.empty.title"), L10n.t("export.empty.info")); return }
        exportInFlight = true
        let sp = NSSavePanel()
        sp.allowedContentTypes = [.zip]
        sp.nameFieldStringValue = "klip-selection.zip"
        sp.canCreateDirectories = true
        if exportable < items.count {
            sp.message = String(format: L10n.t("export.partial"), exportable, items.count)
        }
        modalCount += 1
        NSApp.activate(ignoringOtherApps: true)
        sp.begin { [weak self] resp in
            guard let self else { return }
            self.modalCount -= 1
            guard resp == .OK, let url = sp.url else { self.exportInFlight = false; return }
            self.manager.pauseMonitoring()   // keeps the poll's trim from deleting selected media mid-copy
            DispatchQueue.global(qos: .userInitiated).async {
                let err: Error? = { do { try Storage.shared.exportItemsZip(items, to: url); return nil } catch { return error } }()
                DispatchQueue.main.async {
                    self.manager.resumeMonitoring()
                    self.exportInFlight = false
                    if let err { self.showAlert(L10n.t("export.fail.title"), err.localizedDescription) }   // don't fail silently
                }
            }
        }
    }

    private func showAlert(_ title: String, _ info: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func assignSelectedToCollection(_ items: [ClipboardItem]) {
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("collection.add.title")
        alert.informativeText = L10n.t("collection.add.info")
        alert.addButton(withTitle: L10n.t("common.ok"))
        let cancel = alert.addButton(withTitle: L10n.t("common.cancel")); cancel.keyEquivalent = "\u{1b}"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        // Prefill only if ALL share the same collection; if they differ, leave it empty (don't overwrite
        // with an arbitrary collection from the heterogeneous batch).
        let current = Set(items.map { $0.collection ?? "" })
        field.stringValue = current.count == 1 ? (current.first ?? "") : ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        isRenaming = true
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        isRenaming = false
        if resp == .alertFirstButtonReturn {
            manager.assignCollection(Set(items.map { $0.id }), to: field.stringValue)
        }
        if panel.isVisible { panel.makeKeyAndOrderFront(nil); selection.focusToken &+= 1 }
    }

    /// Global voice shortcut: opens the dedicated recording popup and toggles record/stop.
    func toggleVoiceRecording() {
        MainActor.assumeIsolated {
            if recorder.state == .recording { recorder.stop(); return }
            guard !recorder.isRecording else { return }
            if recordingPanel?.isVisible != true {   // when re-recording with the popup open, keep the original app
                previousApp = NSWorkspace.shared.frontmostApplication
            }
            showRecordingPopup()
            recorder.start()
        }
    }

    private func showRecordingPopup() {
        if recordingPanel == nil {
            let view = RecordingView(
                recorder: recorder,
                onStop: { [weak self] in MainActor.assumeIsolated { self?.recorder.stop() } },
                onCancel: { [weak self] in MainActor.assumeIsolated { self?.recorder.cancel() } },
                onClose: { [weak self] in self?.closeRecordingPopup() },
                onOpenPreferences: { [weak self] in
                    guard let self else { return }
                    // The popup closes right after this (recorder.reset → onClose) and would hand focus
                    // back to the previous app, leaving Preferences BEHIND it. Drop the restore target
                    // and activate ourselves so Preferences lands in front.
                    self.previousApp = nil
                    self.onOpenPreferences?()
                    NSApp.activate(ignoringOtherApps: true)
                }
            )
            let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .floating; p.isReleasedWhenClosed = false
            p.isMovableByWindowBackground = true   // draggable from the background (borderless panel with no title bar)
            p.hidesOnDeactivate = false   // don't hide when focus returns to the user's app
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]   // also show over full-screen apps
            let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))
            fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
            fx.wantsLayer = true; fx.layer?.cornerRadius = 16; fx.layer?.masksToBounds = true
            fx.autoresizingMask = [.width, .height]
            let host = NSHostingView(rootView: view)
            host.frame = fx.bounds; host.autoresizingMask = [.width, .height]; fx.addSubview(host)
            p.contentView = fx
            recordingPanel = p
            // Position ONLY on creation: if the user dragged the popup, we don't put it back in the center
            // every time they record again.
            if let screen = NSScreen.main {
                let vf = screen.visibleFrame; let s = p.frame.size
                p.setFrameOrigin(NSPoint(x: vf.midX - s.width / 2, y: vf.midY + 120))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        recordingPanel?.makeKeyAndOrderFront(nil)
        recordingPanel?.orderFrontRegardless()
    }

    private func closeRecordingPopup() {
        recordingPanel?.orderOut(nil)
        previousApp?.activate()   // transcription runs in the background; we only restore focus
    }

    /// First-run onboarding window. Shown once; "Get started" sets the flag and closes it.
    func showWelcome() {
        if welcomeWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 580),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L10n.t("win.welcome")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WelcomeView(onStart: { [weak self] in
                Settings.shared.hasSeenWelcome = true
                self?.welcomeWindow?.orderOut(nil)
            }))
            w.center()
            welcomeWindow = w
        }
        Settings.shared.hasSeenWelcome = true   // shown once: doesn't reappear even if closed with the red button
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.orderFrontRegardless()
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    func showGuide() {
        if guideWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L10n.t("win.guide")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: GuideView())
            w.center()
            guideWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        guideWindow?.makeKeyAndOrderFront(nil)
    }

    /// Opens the "Upload audio to transcribe" window. Shared entry point for the history panel
    /// button, the menu bar item, and the global shortcut.
    func uploadAudio() {
        // recorder.state is shared; clear a previous .error/.missingAPIKey to show the dropzone — but NOT
        // while the recording popup is on screen (that would wipe its own error/state).
        if recorder.state != .recording, recordingPanel?.isVisible != true { recorder.reset() }
        // Fresh session (nothing in flight): start with an empty results list so no stale results linger.
        if recorder.transcribingCount == 0 { recorder.clearUploadResults() }
        showUploadWindow()
    }

    private func showUploadWindow() {
        if uploadWindow == nil {
            let view = UploadView(
                recorder: recorder,
                onChoose: { [weak self] lang in self?.chooseAudioFiles(language: lang) },
                onFiles: { [weak self] urls, lang in MainActor.assumeIsolated { self?.submitAudioFiles(urls, language: lang) } },
                onClose: { [weak self] in self?.uploadWindow?.orderOut(nil) },
                onOpenPreferences: { [weak self] in self?.onOpenPreferences?() },
                onCopy: { [weak self] in self?.manager.setClipboardText($0) }
            )
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 440),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = L10n.t("win.upload")
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 400, height: 360)
            w.contentView = NSHostingView(rootView: view)
            w.center()
            uploadWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        uploadWindow?.makeKeyAndOrderFront(nil)
    }

    private func chooseAudioFiles(language: String) {
        let p = NSOpenPanel()
        // Audio + video: a video's audio track is extracted before transcribing (see MediaAudioExtractor).
        // WhatsApp's .opus doesn't always conform to public.audio, so we add it (and .oga) explicitly; the
        // video extensions cover containers macOS registers no UTType for (mkv/webm → nil, harmless).
        let types = [UTType.audio, .movie, .audiovisualContent]
            + ["opus", "oga"].compactMap { UTType(filenameExtension: $0) }
            + MediaAudioExtractor.videoExtensions.compactMap { UTType(filenameExtension: $0) }
        p.allowedContentTypes = types
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        modalCount += 1   // keeps the history panel from closing while this open panel is on screen
        NSApp.activate(ignoringOtherApps: true)
        p.begin { [weak self] resp in
            self?.modalCount -= 1
            guard resp == .OK, !p.urls.isEmpty else { return }
            MainActor.assumeIsolated { self?.submitAudioFiles(p.urls, language: language) }
        }
    }

    /// Submits the audio files for transcription (in the background). The window stays open showing the progress
    /// ("Transcribing N…"); the user closes it whenever they want (the notes show up in the history).
    @MainActor
    private func submitAudioFiles(_ urls: [URL], language: String) {
        recorder.transcribeFiles(urls, language: language)
    }

    /// Retries transcribing a failed voice note (uses its stored audio).
    private func retryTranscription(_ item: ClipboardItem) {
        guard let af = item.audioFileName, Storage.shared.audioExists(fileName: af) else { return }
        // Prevents a second retry (double click) while one is in flight → doesn't duplicate the API call.
        guard manager.items.first(where: { $0.id == item.id })?.transcribing != true else { return }
        guard AIProvider.hasKey else { onOpenPreferences?(); return }   // no key: offer to set it up
        MainActor.assumeIsolated { recorder.retry(itemID: item.id, audioFileName: af) }
    }

    /// Deletes an item. Clips with an image/audio file ask for confirmation first (the file on disk
    /// is removed permanently); plain text clips are deleted immediately.
    private func confirmDelete(_ item: ClipboardItem) {
        guard item.imageFileName != nil || item.audioFileName != nil else { manager.delete(item); return }
        let alert = NSAlert()
        alert.messageText = L10n.t("delete.confirm.title")
        alert.informativeText = L10n.t("delete.confirm.info")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("common.delete")).hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: L10n.t("common.cancel"))
        cancel.keyEquivalent = "\u{1b}"   // Esc cancels (not assigned automatically for a localized title)
        isRenaming = true   // same modal guard as renameItem: don't auto-close the panel behind the alert
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        isRenaming = false
        if resp == .alertFirstButtonReturn { manager.delete(item) }
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            selection.focusToken &+= 1   // restore focus to the search field (without clearing search/filter)
        }
    }

    /// Dialog to set (or change) any item's name. Searchable afterwards.
    private func renameItem(_ item: ClipboardItem) {
        let alert = NSAlert()
        alert.messageText = L10n.t("rename.title")
        alert.informativeText = L10n.t("rename.info")
        alert.addButton(withTitle: L10n.t("rename.save"))
        let cancel = alert.addButton(withTitle: L10n.t("common.cancel"))
        cancel.keyEquivalent = "\u{1b}"   // Esc cancels (not assigned automatically for the Spanish title)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = item.name ?? ""
        field.placeholderString = L10n.t("rename.placeholder")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        isRenaming = true
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        isRenaming = false
        if resp == .alertFirstButtonReturn { manager.rename(item, to: field.stringValue) }
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            selection.focusToken &+= 1   // restore focus to the search field (without clearing search/filter)
        }
    }

    private func saveImage(_ item: ClipboardItem) {
        guard item.kind == .image, let fn = item.imageFileName,
              let img = Storage.shared.loadImage(fileName: fn),
              let png = Storage.shared.pngData(from: img) else { return }
        let sp = NSSavePanel()
        sp.allowedContentTypes = [.png]
        sp.nameFieldStringValue = "klip-capture.png"
        sp.canCreateDirectories = true
        modalCount += 1
        NSApp.activate(ignoringOtherApps: true)
        sp.begin { [weak self] resp in
            if resp == .OK, let url = sp.url { try? png.write(to: url, options: .atomic) }
            self?.modalCount -= 1
        }
    }

    // MARK: - NSWindowDelegate (fallback to close when focus is lost)

    func windowDidResignKey(_ notification: Notification) {
        guard !isModalActive, !isRenaming, !recorder.isRecording, !auxWindowVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.isModalActive, !self.isRenaming,
                  !self.recorder.isRecording, !self.auxWindowVisible, !self.panel.isKeyWindow else { return }
            self.hide(restoreFocus: false)
        }
    }
}

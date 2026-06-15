import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Panel flotante que puede recibir el foco de teclado sin volverse ventana principal.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Controla la ventana emergente del historial: vibrancy HUD, posición contextual,
/// aparición animada, navegación por teclado, cierre al clic fuera, auto-pegado, voz y Markdown.
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: KeyablePanel!
    private var effectView: NSVisualEffectView!
    private let manager: ClipboardManager
    private let selection = SelectionModel()
    private let recorder = Recorder()
    private weak var statusItem: NSStatusItem?
    private weak var previousApp: NSRunningApplication?

    /// Lo inyecta AppDelegate para abrir Preferencias desde el panel (estado sin API key).
    var onOpenPreferences: (() -> Void)?

    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var isSavingImage = false
    private let cornerRadius: CGFloat = 12
    private var recordingPanel: NSPanel?
    private var guideWindow: NSWindow?
    private var uploadWindow: NSWindow?
    private var pendingPaste = false

    init(manager: ClipboardManager, statusItem: NSStatusItem?) {
        self.manager = manager
        self.statusItem = statusItem
        super.init()
        buildPanel()
    }

    private func buildPanel() {
        recorder.onTranscribed = { [weak self] text in self?.manager.addVoiceNoteText(text) }

        let root = HistoryView(
            manager: manager,
            selection: selection,
            recorder: recorder,
            onPick: { [weak self] item in self?.pick(item) },
            onSaveImage: { [weak self] item in self?.saveImage(item) },
            onCopyMarkdown: { [weak self] item in self?.copyMarkdown(of: item) },
            onCopyAllMarkdown: { [weak self] in self?.copyAllMarkdown() },
            onOpenPreferences: { [weak self] in self?.onOpenPreferences?() },
            onUploadAudio: { [weak self] in self?.uploadAudio() },
            onVoiceRecord: { [weak self] in self?.toggleVoiceRecording() },
            onShowGuide: { [weak self] in self?.showGuide() }
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

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        guard !panel.isVisible else { return }   // idempotente: evita reinstalar monitores
        previousApp = NSWorkspace.shared.frontmostApplication
        positionPanel()

        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        selection.reset()
        selection.openToken &+= 1                 // dispara reseteo de búsqueda/foco en la vista
        if recordingPanel?.isVisible != true { recorder.reset() }  // no cerrar el popup de voz si está abierto

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        installMonitors()
    }

    func hide(restoreFocus: Bool = true) {
        removeMonitors()
        panel.orderOut(nil)
        if restoreFocus { previousApp?.activate() }
    }

    // MARK: - Monitores (teclado + clic fuera)

    private func installMonitors() {
        removeMonitors()   // nunca dejar monitores huérfanos
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { e in e }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isSavingImage, !self.recorder.isBusy else { return }
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53 {   // Esc (el monitor siempre corre en el hilo principal)
            if recorder.state == .recording {
                MainActor.assumeIsolated { recorder.cancel() }   // aborta la grabación, no cierra
            } else if !recorder.isBusy {
                hide(restoreFocus: true)                         // no cerrar mientras transcribe
            }
            return nil
        }

        // ⌘1..⌘9 → selección rápida + pegar (solo si existe ese índice).
        if flags.contains(.command),
           let ch = event.charactersIgnoringModifiers,
           let n = Int(ch), (1...9).contains(n) {
            if n <= selection.visibleCount { selection.selectQuick(n); pickSelected() }
            return nil
        }
        if flags.contains(.command) { return event }   // no romper ⌘A/⌘C/⌘V en la búsqueda

        switch event.keyCode {
        case 125: selection.moveDown(); return nil    // ↓
        case 126: selection.moveUp();   return nil    // ↑
        case 36, 76: pickSelected();    return nil    // Return / Enter
        default: return event
        }
    }

    // MARK: - Posicionamiento

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
        let hiX = max(vf.minX + 8, vf.maxX - size.width - 8)   // garantiza lo <= hi en pantallas pequeñas
        let hiY = max(vf.minY + 8, vf.maxY - size.height - 8)
        let cx = min(max(x, vf.minX + 8), hiX)
        let cy = min(max(y, vf.minY + 8), hiY)
        return NSPoint(x: cx, y: cy)
    }

    // MARK: - Acciones

    private func pick(_ item: ClipboardItem) {
        manager.copyToPasteboard(item)
        let target = previousApp
        hide(restoreFocus: false)
        if item.isCredential == true { target?.activate() }   // no auto-pegar secretos: solo copiar + devolver foco
        else { pasteOrRestore(target) }
    }

    private func pickSelected() {
        guard let id = selection.selectedID,
              let item = manager.items.first(where: { $0.id == id }) else { return }
        pick(item)
    }

    /// Pega automáticamente en la app previa (si hay permiso y app destino), o solo restaura el foco.
    private func pasteOrRestore(_ target: NSRunningApplication?) {
        guard let target, !target.isTerminated else { return }   // sin destino: solo queda copiado
        if Settings.shared.autoPaste { Paster.paste(into: target) }
        else { target.activate() }
    }

    private func copyMarkdown(of item: ClipboardItem) {
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

    /// Atajo global de voz: abre el popup dedicado de grabación y alterna grabar/detener.
    func toggleVoiceRecording() {
        MainActor.assumeIsolated {
            if recorder.state == .recording { recorder.stop(); return }
            guard !recorder.isBusy else { return }
            if recordingPanel?.isVisible != true {   // al re-grabar con el popup abierto, conservar la app original
                previousApp = NSWorkspace.shared.frontmostApplication
            }
            pendingPaste = false                                    // (el estado ya queda en .idle al cerrar)
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
                onPaste: { [weak self] in self?.pendingPaste = true; self?.recorder.reset() },
                onOpenPreferences: { [weak self] in self?.onOpenPreferences?() }
            )
            let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .floating; p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false   // no ocultarse al volver el foco a la app del usuario
            let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))
            fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
            fx.wantsLayer = true; fx.layer?.cornerRadius = 16; fx.layer?.masksToBounds = true
            fx.autoresizingMask = [.width, .height]
            let host = NSHostingView(rootView: view)
            host.frame = fx.bounds; host.autoresizingMask = [.width, .height]; fx.addSubview(host)
            p.contentView = fx
            recordingPanel = p
        }
        if let screen = NSScreen.main, let p = recordingPanel {
            let vf = screen.visibleFrame; let s = p.frame.size
            p.setFrameOrigin(NSPoint(x: vf.midX - s.width / 2, y: vf.midY + 120))
        }
        NSApp.activate(ignoringOtherApps: true)
        recordingPanel?.makeKeyAndOrderFront(nil)
    }

    private func closeRecordingPopup() {
        recordingPanel?.orderOut(nil)
        let target = previousApp
        if pendingPaste { pendingPaste = false; pasteOrRestore(target) }   // pegar la nota transcrita
        else { target?.activate() }                                        // solo devolver el foco
    }

    func showGuide() {
        if guideWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Guía de Klip"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: GuideView())
            w.center()
            guideWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        guideWindow?.makeKeyAndOrderFront(nil)
    }

    private func uploadAudio() { showUploadWindow() }

    private func showUploadWindow() {
        if uploadWindow == nil {
            let view = UploadView(
                recorder: recorder,
                onChoose: { [weak self] in self?.chooseAudioFiles() },
                onFiles: { [weak self] urls in MainActor.assumeIsolated { self?.recorder.transcribeFiles(urls) } },
                onClose: { [weak self] in self?.uploadWindow?.orderOut(nil) },
                onOpenPreferences: { [weak self] in self?.onOpenPreferences?() }
            )
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Subir audio"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view)
            w.center()
            uploadWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        uploadWindow?.makeKeyAndOrderFront(nil)
    }

    private func chooseAudioFiles() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        p.begin { [weak self] resp in
            guard resp == .OK, !p.urls.isEmpty else { return }
            MainActor.assumeIsolated { self?.recorder.transcribeFiles(p.urls) }
        }
    }

    private func saveImage(_ item: ClipboardItem) {
        guard item.kind == .image, let fn = item.imageFileName,
              let img = Storage.shared.loadImage(fileName: fn),
              let png = Storage.shared.pngData(from: img) else { return }
        let sp = NSSavePanel()
        sp.allowedContentTypes = [.png]
        sp.nameFieldStringValue = "captura.png"
        sp.canCreateDirectories = true
        isSavingImage = true
        NSApp.activate(ignoringOtherApps: true)
        sp.begin { [weak self] resp in
            if resp == .OK, let url = sp.url { try? png.write(to: url, options: .atomic) }
            self?.isSavingImage = false
        }
    }

    // MARK: - NSWindowDelegate (respaldo de cierre al perder el foco)

    func windowDidResignKey(_ notification: Notification) {
        guard !isSavingImage, !recorder.isBusy else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.isSavingImage, !self.recorder.isBusy,
                  !self.panel.isKeyWindow else { return }
            self.hide(restoreFocus: false)
        }
    }
}

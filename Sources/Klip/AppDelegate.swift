import AppKit
import Carbon.HIToolbox
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let recentsMenu = NSMenu()
    private static let recentsDF: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale.current; f.dateFormat = "dd MMM HH:mm"; return f
    }()
    private let manager = ClipboardManager()
    private var panelController: PanelController!
    private var snapController: SnapController!
    private var hotKey: HotKey?
    private var voiceHotKey: HotKey?
    private var captureHotKey: HotKey?
    private var lastGoodCombo = Settings.shared.combo
    private var lastGoodVoiceCombo = Settings.shared.voiceCombo
    private var lastGoodCaptureCombo = Settings.shared.captureCombo
    private var prefsController: PreferencesWindowController?
    private var launchItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Klip")?
                .withSymbolConfiguration(cfg)
        }
        installMainMenu()
        buildMenu()
        panelController = PanelController(manager: manager, statusItem: statusItem)
        panelController.onOpenPreferences = { [weak self] in self?.openPreferences() }
        snapController = SnapController(manager: manager)
        snapController.onCaptured = { [weak self] in self?.panelController.show() }
        panelController.onCaptureAnnotate = { [weak self] in self?.snapController.start() }
        manager.start()
        setupHotKeys()
        maybeEnableLoginOnce()
        // On-device is the default: pre-load (and, if first run, download) the model now so the first
        // voice note transcribes immediately instead of waiting on a cold model load/download.
        if Settings.shared.aiProvider == "local" {
            let m = Settings.shared.localModel
            Task.detached(priority: .utility) { await LocalTranscriber.shared.prewarm(model: m) }
        }
        Settings.shared.$uiLanguage.dropFirst().sink { [weak self] _ in self?.buildMenu() }.store(in: &cancellables)
    }

    // An accessory app (.accessory) has no main menu, so SwiftUI text fields don't receive
    // ⌘X/⌘C/⌘V/⌘A (there's no "Edit" menu to route those shortcuts through the responder
    // chain). We install a minimal main menu with a standard Edit menu.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu (needed so the Edit menu appears as the second one).
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Edit menu with the standard shortcuts (nil target → responder chain).
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "\(L10n.t("menu.show"))   \(Settings.shared.combo.displayString)",
                     action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(withTitle: "\(L10n.t("rec.record"))   \(Settings.shared.voiceCombo.displayString)",
                     action: #selector(startVoice), keyEquivalent: "")
        menu.addItem(withTitle: "\(L10n.t("menu.capture"))   \(Settings.shared.captureCombo.displayString)",
                     action: #selector(startCapture), keyEquivalent: "")
        menu.addItem(.separator())
        let recents = NSMenuItem(title: L10n.t("menu.recents"), action: nil, keyEquivalent: "")
        recentsMenu.delegate = self
        recents.submenu = recentsMenu
        menu.addItem(recents)
        menu.addItem(.separator())
        let prefs = menu.addItem(withTitle: L10n.t("menu.prefs"), action: #selector(openPreferences), keyEquivalent: ",")
        prefs.keyEquivalentModifierMask = [.command]
        let launch = NSMenuItem(title: L10n.t("menu.login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.state = LoginItem.shared.isEnabledOrPending ? .on : .off
        menu.addItem(launch); self.launchItem = launch
        menu.addItem(withTitle: L10n.t("menu.autopaste"), action: #selector(enableAutoPaste), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("act.guide"), action: #selector(showGuideMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("menu.export"), action: #selector(exportBackup), keyEquivalent: "")
        menu.addItem(withTitle: L10n.t("menu.import"), action: #selector(importBackup), keyEquivalent: "")
        menu.addItem(withTitle: L10n.t("menu.clear"), action: #selector(clearAll), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { if $0.target == nil { $0.target = self } }
        statusItem.menu = menu
    }

    private func makePanelHotKey(_ c: KeyCombo) {
        hotKey = HotKey(keyCode: c.keyCode, modifiers: c.carbonModifiers, id: 1) { [weak self] in
            self?.panelController.toggle()
        }
    }
    private func makeVoiceHotKey(_ c: KeyCombo) {
        voiceHotKey = HotKey(keyCode: c.keyCode, modifiers: c.carbonModifiers, id: 2) { [weak self] in
            self?.panelController.toggleVoiceRecording()
        }
    }
    private func makeCaptureHotKey(_ c: KeyCombo) {
        captureHotKey = HotKey(keyCode: c.keyCode, modifiers: c.carbonModifiers, id: 3) { [weak self] in
            self?.snapController.start()
        }
    }

    private func setupHotKeys() {
        makePanelHotKey(Settings.shared.combo)
        makeVoiceHotKey(Settings.shared.voiceCombo)
        makeCaptureHotKey(Settings.shared.captureCombo)
        // If a persisted combination collides with another at startup (HotKey.init returns nil), the
        // shortcut would stay dead for the whole session. Recover with its default shortcut so it isn't lost.
        if hotKey == nil, Settings.shared.combo != .defaultCombo {
            Settings.shared.combo = .defaultCombo; lastGoodCombo = .defaultCombo; makePanelHotKey(.defaultCombo)
        }
        if voiceHotKey == nil, Settings.shared.voiceCombo != .defaultVoiceCombo {
            Settings.shared.voiceCombo = .defaultVoiceCombo; lastGoodVoiceCombo = .defaultVoiceCombo; makeVoiceHotKey(.defaultVoiceCombo)
        }
        if captureHotKey == nil, Settings.shared.captureCombo != .defaultCaptureCombo {
            Settings.shared.captureCombo = .defaultCaptureCombo; lastGoodCaptureCombo = .defaultCaptureCombo; makeCaptureHotKey(.defaultCaptureCombo)
        }
        // If even the default capture shortcut (⌘⇧U) collides (e.g. another app already took it),
        // try the suggested combinations so capture isn't left inert without the user knowing.
        if captureHotKey == nil {
            for s in KeyCombo.suggestions where s != Settings.shared.combo && s != Settings.shared.voiceCombo {
                makeCaptureHotKey(s)
                if captureHotKey != nil {
                    Settings.shared.captureCombo = s; lastGoodCaptureCombo = s
                    showAlert(L10n.t("hotkey.capture.changed.title"), L10n.t("hotkey.capture.changed.info"))
                    break
                }
            }
        }
        // If the panel/voice shortcuts are still dead after the default-reset (another app globally owns
        // even the default combo), tell the user instead of leaving a silently-inert shortcut.
        if hotKey == nil || voiceHotKey == nil {
            NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse"))
        }
    }

    private enum ShortcutKind { case panel, voice, capture }

    /// Carbon registers each shortcut under a distinct id, so it does NOT reject assigning the SAME combo
    /// to two of our shortcuts — we must catch that ourselves.
    private func collidesWithOtherShortcut(_ combo: KeyCombo, _ kind: ShortcutKind) -> Bool {
        switch kind {
        case .panel:   return combo == Settings.shared.voiceCombo || combo == Settings.shared.captureCombo
        case .voice:   return combo == Settings.shared.combo || combo == Settings.shared.captureCombo
        case .capture: return combo == Settings.shared.combo || combo == Settings.shared.voiceCombo
        }
    }

    private func applyCaptureHotKey(_ combo: KeyCombo) {
        if collidesWithOtherShortcut(combo, .capture) {
            NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse"))
            Settings.shared.captureCombo = lastGoodCaptureCombo; buildMenu(); return
        }
        let ok: Bool
        if captureHotKey == nil { makeCaptureHotKey(combo); ok = (captureHotKey != nil) }   // was dead: re-create
        else { ok = captureHotKey?.reRegister(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) == true }
        if ok { lastGoodCaptureCombo = combo }
        else { NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse")); Settings.shared.captureCombo = lastGoodCaptureCombo }
        buildMenu()
    }

    private func applyHotKey(_ combo: KeyCombo) {
        if collidesWithOtherShortcut(combo, .panel) {
            NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse"))
            Settings.shared.combo = lastGoodCombo; buildMenu(); return
        }
        let ok: Bool
        if hotKey == nil { makePanelHotKey(combo); ok = (hotKey != nil) }
        else { ok = hotKey?.reRegister(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) == true }
        if ok { lastGoodCombo = combo }
        else { NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse")); Settings.shared.combo = lastGoodCombo }   // collision: revert
        buildMenu()
    }

    private func applyVoiceHotKey(_ combo: KeyCombo) {
        if collidesWithOtherShortcut(combo, .voice) {
            NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse"))
            Settings.shared.voiceCombo = lastGoodVoiceCombo; buildMenu(); return
        }
        let ok: Bool
        if voiceHotKey == nil { makeVoiceHotKey(combo); ok = (voiceHotKey != nil) }
        else { ok = voiceHotKey?.reRegister(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) == true }
        if ok { lastGoodVoiceCombo = combo }
        else { NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse")); Settings.shared.voiceCombo = lastGoodVoiceCombo }
        buildMenu()
    }

    private func maybeEnableLoginOnce() {
        let key = "didAutoEnableLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        LoginItem.shared.registerIfNeeded()
        // Mark "done" only once registration actually took. On first launch the app can be translocated
        // (registration fails); leaving the flag unset lets it retry on a later launch from /Applications.
        if LoginItem.shared.isEnabledOrPending { UserDefaults.standard.set(true, forKey: key) }
        launchItem?.state = LoginItem.shared.isEnabledOrPending ? .on : .off
    }

    // "Recents" submenu: rebuilt every time it's opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentsMenu else { return }
        menu.removeAllItems()
        let items = manager.items.sorted { $0.createdAt > $1.createdAt }.prefix(10)
        if items.isEmpty {
            let empty = NSMenuItem(title: L10n.t("menu.empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for it in items {
            let icon = it.isVoiceNote == true ? "🎙 " : (it.kind == .image ? "🖼 " : (it.isCredential == true ? "🔑 " : ""))
            let body: String
            if let nm = it.name, !nm.isEmpty { body = String(nm.prefix(45)) }   // name set by the user
            else if it.isCredential == true { body = CredentialDetector.masked(it.text ?? "") }
            else if it.isVoiceNote == true {
                // transcribed text (avoids a double 🎙); if there's none yet, use the preview without the emoji.
                let tx = (it.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                body = tx.isEmpty ? String(it.preview.drop(while: { $0 == "🎙" || $0 == " " }).prefix(45))
                                  : String(tx.prefix(45))
            }
            else { body = String(it.preview.prefix(45)) }
            let mi = NSMenuItem(title: "\(Self.recentsDF.string(from: it.createdAt))   \(icon)\(body)",
                                action: #selector(pasteRecent(_:)), keyEquivalent: "")
            mi.representedObject = it.id
            mi.target = self
            menu.addItem(mi)
        }
    }

    @objc private func pasteRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let item = manager.items.first(where: { $0.id == id }) else { return }
        // Voice note without transcription: there's no text to copy → play its audio.
        if item.kind == .text, (item.text?.isEmpty ?? true) {
            if let af = item.audioFileName { AudioPlayer.shared.toggle(fileName: af) }
            return
        }
        manager.copyToPasteboard(item)   // lands on the pasteboard, ready to paste
    }

    @objc private func showPanel() { panelController.show() }
    @objc private func startVoice() { panelController.toggleVoiceRecording() }
    @objc private func startCapture() { snapController.start() }
    @objc private func showGuideMenu() { panelController.showGuide() }

    @objc private func openPreferences() {
        if prefsController == nil {
            prefsController = PreferencesWindowController(
                onHotKeyChange: { [weak self] combo in self?.applyHotKey(combo) },
                onVoiceHotKeyChange: { [weak self] combo in self?.applyVoiceHotKey(combo) },
                onCaptureHotKeyChange: { [weak self] combo in self?.applyCaptureHotKey(combo) },
                onMaxItemsChange: { [weak self] in self?.manager.applyMaxItems() })
        }
        prefsController?.show()
    }

    @objc private func toggleLaunchAtLogin() {
        switch LoginItem.shared.toggle() {
        case .success:
            launchItem?.state = LoginItem.shared.isEnabledOrPending ? .on : .off
        case .failure(let err):
            if case .requiresApproval = err { LoginItem.shared.openSystemSettings() }
            let alert = NSAlert()
            alert.messageText = L10n.t("login.title")
            alert.informativeText = err.localizedDescription
            alert.runModal()
            launchItem?.state = LoginItem.shared.isEnabledOrPending ? .on : .off
        }
    }

    @objc private func enableAutoPaste() {
        if Paster.ensureAccessibilityPermission(prompt: true) {
            showAlert(L10n.t("autopaste.enabled.title"), L10n.t("autopaste.enabled.info"))
        } else {
            // Not granted yet: the system dialog opened asynchronously. Tell the user what to do, instead
            // of silently doing nothing (the common case — they clicked this because it wasn't working).
            showAlert(L10n.t("autopaste.denied.title"), L10n.t("autopaste.denied.info"))
        }
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("clear.title")
        alert.informativeText = L10n.t("clear.info")
        let del = alert.addButton(withTitle: L10n.t("clear.confirm"))
        del.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: L10n.t("common.cancel"))
        cancel.keyEquivalent = "\u{1b}"   // Esc cancels (it isn't assigned automatically in Spanish)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { manager.clearAll() }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func exportBackup() {
        let sp = NSSavePanel()
        sp.allowedContentTypes = [.zip]
        sp.nameFieldStringValue = "Klip-backup.zip"
        sp.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        sp.begin { [weak self] resp in
            guard resp == .OK, let url = sp.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {   // ditto + heavy copy: off the main thread
                do { try Storage.shared.exportBackup(to: url) }
                catch { DispatchQueue.main.async { self?.showAlert(L10n.t("export.fail"), error.localizedDescription) } }
            }
        }
    }

    @objc private func importBackup() {
        let op = NSOpenPanel()
        op.allowedContentTypes = [.zip]
        op.allowsMultipleSelection = false
        op.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        op.begin { [weak self] resp in
            guard let self, resp == .OK, let url = op.url else { return }
            // Don't import while a voice note is still transcribing: the import replaces the audio
            // directory and items, and the in-flight transcription would resolve against stale ids.
            guard !self.manager.hasActiveTranscription, !self.panelController.isBusyWithAudio else {
                self.showAlert(L10n.t("import.busy.title"), L10n.t("import.busy.info")); return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.t("import.title")
            alert.informativeText = L10n.t("import.info")
            let ok = alert.addButton(withTitle: L10n.t("import.confirm")); ok.hasDestructiveAction = true
            let cancel = alert.addButton(withTitle: L10n.t("common.cancel")); cancel.keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.manager.pauseMonitoring()   // keep the poll from writing to the store during the import
            DispatchQueue.global(qos: .userInitiated).async {   // ditto + heavy copy: off the main thread
                do {
                    let items = try Storage.shared.importBackup(from: url)
                    DispatchQueue.main.async { self.manager.reload(items); self.manager.resumeMonitoring() }
                } catch {
                    DispatchQueue.main.async { self.showAlert(L10n.t("import.fail"), error.localizedDescription); self.manager.resumeMonitoring() }
                }
            }
        }
    }

    private func showAlert(_ title: String, _ info: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        a.addButton(withTitle: "OK"); a.runModal()
    }
}

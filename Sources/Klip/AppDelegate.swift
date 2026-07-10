import AppKit
import SwiftUI
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
    /// Short localized stamp for meeting-note names ("9 Jul 2026, 14:03" style).
    private static let meetingDF: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale.current; f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    private let manager = ClipboardManager()
    private var panelController: PanelController!
    private var snapController: SnapController!
    private var hotKey: HotKey?
    private var voiceHotKey: HotKey?
    private var captureHotKey: HotKey?
    private var uploadHotKey: HotKey?
    private var textCaptureHotKey: HotKey?
    private var meetingHotKey: HotKey?
    private var lastGoodCombo = Settings.shared.combo
    private var lastGoodVoiceCombo = Settings.shared.voiceCombo
    private var lastGoodCaptureCombo = Settings.shared.captureCombo
    private var lastGoodUploadCombo = Settings.shared.uploadCombo
    private var lastGoodTextCaptureCombo = Settings.shared.textCaptureCombo
    private var lastGoodMeetingCombo = Settings.shared.meetingCombo
    private let meetingRecorder = MeetingRecorder()
    private var meetingItem: NSMenuItem?
    private var meetingHUD: NSPanel?
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
        // Meeting recording (mic + system audio → one mixed voice note in the history).
        meetingRecorder.isMicBusy = { [weak self] in self?.panelController.isVoiceRecording ?? false }
        panelController.isMeetingRecording = { [weak self] in self?.meetingRecorder.isRecording ?? false }
        meetingRecorder.onMeetingReady = { [weak self] fileName, duration in
            guard let self else { return nil }
            let id = self.manager.beginVoiceNote(audioFileName: fileName, duration: duration, allowAutoCopy: false)
            if let item = self.manager.items.first(where: { $0.id == id }) {
                self.manager.rename(item, to: "\(L10n.t("meeting.name")) — \(Self.meetingDF.string(from: Date()))")
            }
            // Tell the user WHERE the note went (the HUD is about to close; without this the flow
            // just vanishes): toast with a one-tap way into the history.
            ToastHUD.show(L10n.t("meeting.saved.title"),
                          detail: L10n.t("meeting.saved.detail"),
                          actionTitle: L10n.t("meeting.saved.action")) { [weak self] in
                self?.panelController.show()
            }
            return id
        }
        meetingRecorder.onTranscribe = { [weak self] id, fileName, micURL, systemURL in
            self?.panelController.transcribeMeetingNote(itemID: id, mixedFileName: fileName,
                                                        micURL: micURL, systemURL: systemURL)
        }
        // Red status-item icon while a meeting records + menu title toggle + the live HUD.
        meetingRecorder.$isRecording.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] rec in
                if rec { self?.showMeetingHUD() }
                self?.updateStatusIcon()
                self?.buildMenu()
            }
            .store(in: &cancellables)
        // The HUD stays up through "Mixing & transcribing…" and closes when the note is handed off.
        meetingRecorder.$finishing.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] finishing in
                guard let self, !finishing, !self.meetingRecorder.isRecording else { return }
                self.closeMeetingHUD()
            }
            .store(in: &cancellables)
        MeetingRecorder.sweepOrphanedTempFiles()   // clear unfinalized tracks from a crashed run
        manager.start()
        // Zero-real-estate copy confirmation (Shottr-style): flash the menu-bar icon to a checkmark
        // whenever anything lands on the pasteboard through Klip.
        NotificationCenter.default.addObserver(forName: .klipDidCopy, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flashStatusIcon() }
        }
        setupHotKeys()
        maybeEnableLoginOnce()
        // On-device is the default: pre-load (and, if first run, download) the model now so the first
        // voice note transcribes immediately instead of waiting on a cold model load/download.
        if Settings.shared.aiProvider == "local" {
            let m = Settings.shared.localModel
            Task.detached(priority: .utility) { await LocalTranscriber.shared.prewarm(model: m) }
        }
        // Hop to main explicitly so buildMenu() (@MainActor) is safe no matter where uiLanguage is mutated.
        Settings.shared.$uiLanguage.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.buildMenu() }.store(in: &cancellables)
        // First-run onboarding (clipboard-monitoring + privacy disclosure). Deferred so it never stalls launch.
        if !Settings.shared.hasSeenWelcome {
            DispatchQueue.main.async { [weak self] in self?.panelController.showWelcome() }
        }
    }

    /// Quitting mid-meeting would abandon both temp tracks unfinalized (no moov atom → unplayable)
    /// and lose the whole recording: finish the meeting first (mix + store + item), then terminate.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard meetingRecorder.isRecording else { return .terminateNow }
        Task { @MainActor in
            await meetingRecorder.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

    private var iconFlashWork: DispatchWorkItem?
    private func flashStatusIcon() {
        guard let button = statusItem.button else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(cfg)
        button.contentTintColor = nil   // flash reads the same in every state; updateStatusIcon restores the red record tint
        iconFlashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.updateStatusIcon() }   // restores the meeting-recording icon too
        }
        iconFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Base status-item icon: the red record symbol while a meeting records, the clipboard otherwise.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        if meetingRecorder.isRecording {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recording meeting")?
                .withSymbolConfiguration(cfg)
            button.contentTintColor = .systemRed
        } else {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Klip")?
                .withSymbolConfiguration(cfg)
            button.contentTintColor = nil
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "\(L10n.t("menu.show"))   \(Settings.shared.combo.displayString)",
                     action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(withTitle: "\(L10n.t("rec.record"))   \(Settings.shared.voiceCombo.displayString)",
                     action: #selector(startVoice), keyEquivalent: "")
        let meeting = menu.addItem(withTitle: meetingMenuTitle(),
                                   action: #selector(toggleMeetingRecording), keyEquivalent: "")
        meetingItem = meeting
        menu.addItem(withTitle: "\(L10n.t("menu.capture"))   \(Settings.shared.captureCombo.displayString)",
                     action: #selector(startCapture), keyEquivalent: "")
        menu.addItem(withTitle: "\(L10n.t("menu.captureText"))   \(Settings.shared.textCaptureCombo.displayString)",
                     action: #selector(startTextCapture), keyEquivalent: "")
        menu.addItem(withTitle: "\(L10n.t("act.upload"))   \(Settings.shared.uploadCombo.displayString)",
                     action: #selector(startUpload), keyEquivalent: "")
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
        menu.delegate = self   // menuNeedsUpdate refreshes the launch-at-login checkmark from current SMAppService state
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
    private func makeUploadHotKey(_ c: KeyCombo) {
        uploadHotKey = HotKey(keyCode: c.keyCode, modifiers: c.carbonModifiers, id: 4) { [weak self] in
            self?.panelController.uploadAudio()
        }
    }
    private func makeTextCaptureHotKey(_ c: KeyCombo) {
        textCaptureHotKey = HotKey(keyCode: c.keyCode, modifiers: c.carbonModifiers, id: 5) { [weak self] in
            self?.snapController.startTextCapture()
        }
    }
    private func makeMeetingHotKey(_ c: KeyCombo) {
        meetingHotKey = HotKey(keyCode: c.keyCode, modifiers: c.carbonModifiers, id: 6) { [weak self] in
            self?.toggleMeetingRecording()
        }
    }

    private func registerHotKey(_ kind: ShortcutKind, _ c: KeyCombo) {
        switch kind {
        case .panel: makePanelHotKey(c)
        case .voice: makeVoiceHotKey(c)
        case .capture: makeCaptureHotKey(c)
        case .upload: makeUploadHotKey(c)
        case .textCapture: makeTextCaptureHotKey(c)
        case .meeting: makeMeetingHotKey(c)
        }
    }
    private func hotKeyLive(_ kind: ShortcutKind) -> Bool {
        switch kind {
        case .panel: return hotKey != nil
        case .voice: return voiceHotKey != nil
        case .capture: return captureHotKey != nil
        case .upload: return uploadHotKey != nil
        case .textCapture: return textCaptureHotKey != nil
        case .meeting: return meetingHotKey != nil
        }
    }
    /// After moving a LIVE shortcut, make sure it actually registered; if the OS rejected the combo (another
    /// app owns it) fall through to the first registerable suggestion, so dedup never persists a dead combo.
    private func ensureLiveRegistered(_ kind: ShortcutKind, avoiding taken: [KeyCombo], commit: (KeyCombo) -> Void) {
        guard !hotKeyLive(kind) else { return }
        for cand in KeyCombo.suggestions where !taken.contains(cand) {
            registerHotKey(kind, cand)
            if hotKeyLive(kind) { commit(cand); return }
        }
    }

    /// A migration (or a manual edit) can leave two of the three shortcuts on the SAME combo. Carbon registers
    /// each under a distinct id, so BOTH succeed and one keypress fires two actions. Break duplicates before
    /// registering: keep the panel combo, move voice/capture off any clash to a free suggestion (or default).
    private func deduplicateShortcuts() {
        let s = Settings.shared
        func free(_ taken: [KeyCombo], _ fallback: KeyCombo) -> KeyCombo {
            if !taken.contains(fallback) { return fallback }
            return KeyCombo.suggestions.first { !taken.contains($0) } ?? fallback
        }
        // Re-register only when already live (i.e. when called AGAIN after startup recovery) — on the first
        // call the make*HotKey calls right after handle registration.
        if s.voiceCombo == s.combo {
            let fixed = free([s.combo], .defaultVoiceCombo); s.voiceCombo = fixed; lastGoodVoiceCombo = fixed
            if voiceHotKey != nil {
                makeVoiceHotKey(fixed)
                ensureLiveRegistered(.voice, avoiding: [s.combo]) { s.voiceCombo = $0; lastGoodVoiceCombo = $0 }
            }
        }
        if s.captureCombo == s.combo || s.captureCombo == s.voiceCombo {
            let fixed = free([s.combo, s.voiceCombo], .defaultCaptureCombo); s.captureCombo = fixed; lastGoodCaptureCombo = fixed
            if captureHotKey != nil {
                makeCaptureHotKey(fixed)
                ensureLiveRegistered(.capture, avoiding: [s.combo, s.voiceCombo]) { s.captureCombo = $0; lastGoodCaptureCombo = $0 }
            }
        }
        if s.uploadCombo == s.combo || s.uploadCombo == s.voiceCombo || s.uploadCombo == s.captureCombo {
            let fixed = free([s.combo, s.voiceCombo, s.captureCombo], .defaultUploadCombo); s.uploadCombo = fixed; lastGoodUploadCombo = fixed
            if uploadHotKey != nil {
                makeUploadHotKey(fixed)
                ensureLiveRegistered(.upload, avoiding: [s.combo, s.voiceCombo, s.captureCombo]) { s.uploadCombo = $0; lastGoodUploadCombo = $0 }
            }
        }
        let used = [s.combo, s.voiceCombo, s.captureCombo, s.uploadCombo]
        if used.contains(s.textCaptureCombo) {
            let fixed = free(used, .defaultTextCaptureCombo); s.textCaptureCombo = fixed; lastGoodTextCaptureCombo = fixed
            if textCaptureHotKey != nil {
                makeTextCaptureHotKey(fixed)
                ensureLiveRegistered(.textCapture, avoiding: used) { s.textCaptureCombo = $0; lastGoodTextCaptureCombo = $0 }
            }
        }
        let used6 = [s.combo, s.voiceCombo, s.captureCombo, s.uploadCombo, s.textCaptureCombo]
        if used6.contains(s.meetingCombo) {
            let fixed = free(used6, .defaultMeetingCombo); s.meetingCombo = fixed; lastGoodMeetingCombo = fixed
            if meetingHotKey != nil {
                makeMeetingHotKey(fixed)
                ensureLiveRegistered(.meeting, avoiding: used6) { s.meetingCombo = $0; lastGoodMeetingCombo = $0 }
            }
        }
    }

    private func setupHotKeys() {
        deduplicateShortcuts()
        makePanelHotKey(Settings.shared.combo)
        makeVoiceHotKey(Settings.shared.voiceCombo)
        makeCaptureHotKey(Settings.shared.captureCombo)
        makeUploadHotKey(Settings.shared.uploadCombo)
        makeTextCaptureHotKey(Settings.shared.textCaptureCombo)
        makeMeetingHotKey(Settings.shared.meetingCombo)
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
        // If even the default capture shortcut collides (e.g. another app already took it), try the suggested
        // combinations so capture isn't left inert without the user knowing.
        if captureHotKey == nil {
            for s in KeyCombo.suggestions where s != Settings.shared.combo && s != Settings.shared.voiceCombo {
                makeCaptureHotKey(s)
                if captureHotKey != nil {
                    Settings.shared.captureCombo = s; lastGoodCaptureCombo = s
                    // Defer the modal: a synchronous runModal here would stall the rest of launch.
                    Task { @MainActor in self.showAlert(L10n.t("hotkey.capture.changed.title"), L10n.t("hotkey.capture.changed.info")) }
                    break
                }
            }
        }
        // Upload is reachable from the menu bar and the history-panel button too, so a dead shortcut here is
        // not critical: recover quietly (default → free suggestion) without interrupting the user with an alert.
        if uploadHotKey == nil, Settings.shared.uploadCombo != .defaultUploadCombo {
            Settings.shared.uploadCombo = .defaultUploadCombo; lastGoodUploadCombo = .defaultUploadCombo
            makeUploadHotKey(.defaultUploadCombo)
        }
        if uploadHotKey == nil {
            for s in KeyCombo.suggestions where s != Settings.shared.combo && s != Settings.shared.voiceCombo && s != Settings.shared.captureCombo {
                makeUploadHotKey(s)
                if uploadHotKey != nil { Settings.shared.uploadCombo = s; lastGoodUploadCombo = s; break }
            }
        }
        // Text-capture (OCR) is also reachable from the menu bar, so recover quietly like upload.
        if textCaptureHotKey == nil, Settings.shared.textCaptureCombo != .defaultTextCaptureCombo {
            Settings.shared.textCaptureCombo = .defaultTextCaptureCombo; lastGoodTextCaptureCombo = .defaultTextCaptureCombo
            makeTextCaptureHotKey(.defaultTextCaptureCombo)
        }
        if textCaptureHotKey == nil {
            let taken = [Settings.shared.combo, Settings.shared.voiceCombo, Settings.shared.captureCombo, Settings.shared.uploadCombo]
            for s in KeyCombo.suggestions where !taken.contains(s) {
                makeTextCaptureHotKey(s)
                if textCaptureHotKey != nil { Settings.shared.textCaptureCombo = s; lastGoodTextCaptureCombo = s; break }
            }
        }
        // Meeting recording is also reachable from the menu bar, so recover quietly like upload/OCR.
        if meetingHotKey == nil, Settings.shared.meetingCombo != .defaultMeetingCombo {
            Settings.shared.meetingCombo = .defaultMeetingCombo; lastGoodMeetingCombo = .defaultMeetingCombo
            makeMeetingHotKey(.defaultMeetingCombo)
        }
        if meetingHotKey == nil {
            let taken = [Settings.shared.combo, Settings.shared.voiceCombo, Settings.shared.captureCombo,
                         Settings.shared.uploadCombo, Settings.shared.textCaptureCombo]
            for s in KeyCombo.suggestions where !taken.contains(s) {
                makeMeetingHotKey(s)
                if meetingHotKey != nil { Settings.shared.meetingCombo = s; lastGoodMeetingCombo = s; break }
            }
        }
        // If the panel/voice shortcuts are still dead after the default-reset (another app globally owns
        // even the default combo), tell the user instead of leaving a silently-inert shortcut (deferred so it
        // doesn't block launch).
        if hotKey == nil || voiceHotKey == nil {
            // Here the combo is owned by ANOTHER app, not by a Klip shortcut → dedicated wording.
            Task { @MainActor in NSSound.beep(); self.showAlert(L10n.t("hotkey.dead.title"), L10n.t("hotkey.dead.info")) }
        }
        // The suggestion-recovery loops above can land one shortcut on a sibling's combo (they don't all
        // exclude every sibling). Run dedup once more — now it re-registers what it moves — so no two
        // shortcuts share a combo (which would fire two actions on one keypress).
        deduplicateShortcuts()
        // Reflect any startup remaps in the menu's shortcut labels.
        buildMenu()
    }

    private enum ShortcutKind { case panel, voice, capture, upload, textCapture, meeting }

    /// Carbon registers each shortcut under a distinct id, so it does NOT reject assigning the SAME combo
    /// to two of our shortcuts — we must catch that ourselves.
    private func collidesWithOtherShortcut(_ combo: KeyCombo, _ kind: ShortcutKind) -> Bool {
        let s = Settings.shared
        let others: [KeyCombo]
        switch kind {
        case .panel:       others = [s.voiceCombo, s.captureCombo, s.uploadCombo, s.textCaptureCombo, s.meetingCombo]
        case .voice:       others = [s.combo, s.captureCombo, s.uploadCombo, s.textCaptureCombo, s.meetingCombo]
        case .capture:     others = [s.combo, s.voiceCombo, s.uploadCombo, s.textCaptureCombo, s.meetingCombo]
        case .upload:      others = [s.combo, s.voiceCombo, s.captureCombo, s.textCaptureCombo, s.meetingCombo]
        case .textCapture: others = [s.combo, s.voiceCombo, s.captureCombo, s.uploadCombo, s.meetingCombo]
        case .meeting:     others = [s.combo, s.voiceCombo, s.captureCombo, s.uploadCombo, s.textCaptureCombo]
        }
        return others.contains(combo)
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

    private func applyUploadHotKey(_ combo: KeyCombo) {
        if collidesWithOtherShortcut(combo, .upload) {
            NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse"))
            Settings.shared.uploadCombo = lastGoodUploadCombo; buildMenu(); return
        }
        let ok: Bool
        if uploadHotKey == nil { makeUploadHotKey(combo); ok = (uploadHotKey != nil) }
        else { ok = uploadHotKey?.reRegister(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) == true }
        if ok { lastGoodUploadCombo = combo }
        else { NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse")); Settings.shared.uploadCombo = lastGoodUploadCombo }
        buildMenu()
    }

    private func applyTextCaptureHotKey(_ combo: KeyCombo) {
        if collidesWithOtherShortcut(combo, .textCapture) {
            NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse"))
            Settings.shared.textCaptureCombo = lastGoodTextCaptureCombo; buildMenu(); return
        }
        let ok: Bool
        if textCaptureHotKey == nil { makeTextCaptureHotKey(combo); ok = (textCaptureHotKey != nil) }
        else { ok = textCaptureHotKey?.reRegister(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) == true }
        if ok { lastGoodTextCaptureCombo = combo }
        else { NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse")); Settings.shared.textCaptureCombo = lastGoodTextCaptureCombo }
        buildMenu()
    }

    private func applyMeetingHotKey(_ combo: KeyCombo) {
        if collidesWithOtherShortcut(combo, .meeting) {
            NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse"))
            Settings.shared.meetingCombo = lastGoodMeetingCombo; buildMenu(); return
        }
        let ok: Bool
        if meetingHotKey == nil { makeMeetingHotKey(combo); ok = (meetingHotKey != nil) }
        else { ok = meetingHotKey?.reRegister(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) == true }
        if ok { lastGoodMeetingCombo = combo }
        else { NSSound.beep(); showAlert(L10n.t("act.prefs"), L10n.t("hotkey.inuse")); Settings.shared.meetingCombo = lastGoodMeetingCombo }
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
        if menu === statusItem.menu {   // approval can happen in System Settings while we run → reflect it on open
            launchItem?.state = LoginItem.shared.isEnabledOrPending ? .on : .off
            meetingItem?.title = meetingMenuTitle()   // refresh the elapsed mm:ss each time the menu opens
            return
        }
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
        // Auto-paste like the panel does. No target: the menu closing already restored focus to the
        // previous app, so just send ⌘V. Never auto-paste credentials — same policy as PanelController.pick.
        if item.isCredential != true, Settings.shared.autoPaste, Paster.hasAccessibilityPermission {
            Paster.paste(into: nil)
        }
    }

    private func meetingMenuTitle() -> String {
        meetingRecorder.isRecording
            ? "\(L10n.t("meeting.stop"))   \(Self.mmss(meetingRecorder.elapsed))"
            : "\(L10n.t("meeting.record"))   \(Settings.shared.meetingCombo.displayString)"
    }
    private static func mmss(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    @objc private func toggleMeetingRecording() {
        if meetingRecorder.isRecording { Task { @MainActor in await meetingRecorder.stop() } }
        else { meetingRecorder.start() }
    }

    /// Small floating HUD (top-right of the active screen) with live meters for both sources —
    /// visible proof the recording is hearing you AND the meeting. Non-activating: doesn't steal
    /// focus from the call.
    private func showMeetingHUD() {
        if meetingHUD == nil {
            let view = MeetingHUDView(
                recorder: meetingRecorder,
                onStop: { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in await self.meetingRecorder.stop() }
                },
                onDiscard: { [weak self] in
                    guard let self else { return }
                    let a = NSAlert()
                    a.messageText = L10n.t("meeting.discard.title")
                    a.informativeText = L10n.t("meeting.discard.info")
                    let d = a.addButton(withTitle: L10n.t("editor.discard.confirm"))
                    d.hasDestructiveAction = true
                    a.addButton(withTitle: L10n.t("common.cancel"))
                    guard a.runModal() == .alertFirstButtonReturn else { return }
                    Task { @MainActor in
                        await self.meetingRecorder.discard()
                        self.closeMeetingHUD()
                        self.updateStatusIcon(); self.buildMenu()
                    }
                })
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 264, height: 150),
                                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: view)
            meetingHUD = panel
        }
        guard let panel = meetingHUD else { return }
        // Fixed size: NSHostingView's fittingSize is 0 before its first layout pass, which made the
        // panel invisible. The SwiftUI content is a fixed 264pt-wide card; height fits all states.
        panel.setContentSize(NSSize(width: 264, height: 168))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - panel.frame.width - 16, y: f.maxY - 12))
        }
        let appearing = !panel.isVisible
        hudFadingOut = false   // cancel a close fade in flight: its completion must not order us out
        if appearing { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        if panel.alphaValue < 1 {   // newly appearing OR caught mid fade-out: fade up to full
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.13
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    /// True while the HUD's close fade-out runs (still visible but going away).
    private var hudFadingOut = false
    private func closeMeetingHUD() {
        guard let hud = meetingHUD, hud.isVisible, !hudFadingOut else { return }
        hudFadingOut = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hud.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hudFadingOut else { return }   // re-shown mid-fade: leave it up
            self.hudFadingOut = false
            hud.orderOut(nil)
            hud.alphaValue = 1   // ready for the next appearance
        })
    }

    @objc private func showPanel() { panelController.show() }
    @objc private func startVoice() { panelController.toggleVoiceRecording() }
    @objc private func startCapture() { snapController.start() }
    @objc private func startTextCapture() { snapController.startTextCapture() }
    @objc private func startUpload() { panelController.uploadAudio() }
    @objc private func showGuideMenu() { panelController.showGuide() }

    @objc private func openPreferences() {
        if prefsController == nil {
            prefsController = PreferencesWindowController(
                onHotKeyChange: { [weak self] combo in self?.applyHotKey(combo) },
                onVoiceHotKeyChange: { [weak self] combo in self?.applyVoiceHotKey(combo) },
                onCaptureHotKeyChange: { [weak self] combo in self?.applyCaptureHotKey(combo) },
                onUploadHotKeyChange: { [weak self] combo in self?.applyUploadHotKey(combo) },
                onTextCaptureHotKeyChange: { [weak self] combo in self?.applyTextCaptureHotKey(combo) },
                onMeetingHotKeyChange: { [weak self] combo in self?.applyMeetingHotKey(combo) },
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
            Settings.shared.autoPaste = true   // make the "enabled" claim true even if the pref was off
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
            guard resp == .OK, let url = sp.url, let self else { return }
            self.manager.pauseMonitoring()   // keep the poll from adding/trimming media mid-copy (it would corrupt the zip)
            DispatchQueue.global(qos: .userInitiated).async {   // ditto + heavy copy: off the main thread
                do {
                    try Storage.shared.exportBackup(to: url)
                    DispatchQueue.main.async { self.manager.resumeMonitoring() }
                } catch {
                    DispatchQueue.main.async { self.showAlert(L10n.t("export.fail"), error.localizedDescription); self.manager.resumeMonitoring() }
                }
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

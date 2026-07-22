import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine
import UniformTypeIdentifiers

/// The eight global shortcuts as one table: everything that differs between them is a property here,
/// so registration, dedup, recovery and the Preferences wiring are all written once.
/// (The scroll-capture session Esc uses id 9 ad hoc — it isn't one of these.)
enum ShortcutKind: CaseIterable {
    case panel, voice, capture, upload, textCapture, meeting, screenRec, scroll

    /// Carbon registration id. STABLE per shortcut: HotKey routes a keypress to the instance holding
    /// this id, so renumbering silently hands a kind someone else's registration.
    var carbonID: UInt32 {
        switch self {
        case .panel:       return 1
        case .voice:       return 2
        case .capture:     return 3
        case .upload:      return 4
        case .textCapture: return 5
        case .meeting:     return 6
        case .screenRec:   return 7
        case .scroll:      return 8
        }
    }

    /// Where this shortcut's combo is persisted.
    var combo: ReferenceWritableKeyPath<Settings, KeyCombo> {
        switch self {
        case .panel:       return \.combo
        case .voice:       return \.voiceCombo
        case .capture:     return \.captureCombo
        case .upload:      return \.uploadCombo
        case .textCapture: return \.textCaptureCombo
        case .meeting:     return \.meetingCombo
        case .screenRec:   return \.screenRecCombo
        case .scroll:      return \.scrollCombo
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .panel:       return .defaultCombo
        case .voice:       return .defaultVoiceCombo
        case .capture:     return .defaultCaptureCombo
        case .upload:      return .defaultUploadCombo
        case .textCapture: return .defaultTextCaptureCombo
        case .meeting:     return .defaultMeetingCombo
        case .screenRec:   return .defaultScreenRecCombo
        case .scroll:      return .defaultScrollCombo
        }
    }

    /// Panel and voice are never silently remapped onto a free suggestion: they're the two the user
    /// gets told about instead (the alert at the end of setupHotKeys). Every other shortcut is also
    /// reachable from the menu bar, so a dead one recovers quietly.
    var recoversViaSuggestions: Bool { self != .panel && self != .voice }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    /// Rebuilt by buildMenu() on every call — see the note there on why it can't be one shared menu.
    private var recentsMenu = NSMenu()
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
    /// A missing entry means "dead": HotKey.init returns nil when the OS refuses the combo.
    private var hotKeys: [ShortcutKind: HotKey] = [:]
    private var lastGood = Dictionary(uniqueKeysWithValues:
        ShortcutKind.allCases.map { ($0, Settings.shared[keyPath: $0.combo]) })
    private let meetingRecorder = MeetingRecorder()
    private let screenRecorder = ScreenRecorder()
    private var recOverlay: CaptureOverlayController?
    private let recIndicator = RecordingIndicator()
    private var scrollOverlay: CaptureOverlayController?
    private var scrollCapture: ScrollCaptureController?
    private let scrollIndicator = RecordingIndicator()
    /// Modifier-less Esc, registered ONLY while a scroll-capture session runs. A local monitor never
    /// worked — Klip isn't the active app during the capture; a Carbon hotkey is delivery-independent.
    private var scrollEscHotKey: HotKey?
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
        panelController.onCaptureAnnotate = { [weak self] in self?.snapController.start() }
        // Meeting recording (mic + system audio → one mixed voice note in the history).
        meetingRecorder.isMicBusy = { [weak self] in self?.panelController.isVoiceRecording ?? false }
        // isBusy (recording OR async starting OR stopping) closes the startup window where a voice
        // recording could grab the mic while the meeting's streams are still coming up.
        panelController.isMeetingRecording = { [weak self] in self?.meetingRecorder.isBusy ?? false }
        // Mute the interface cues while a mic is hot: they play out of the speakers and would be picked
        // up by the voice-note / meeting recorder (no echo cancellation) and transcribed with the note.
        SoundFX.micIsLive = { [weak self] in
            guard let self else { return false }
            return self.meetingRecorder.isBusy || self.panelController.isVoiceRecording
        }
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
        // Screen recording: red icon while live + menu title toggle, and the finished-file toast
        // with its one-tap GIF conversion.
        screenRecorder.$isRecording.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] rec in
                guard let self else { return }
                // The floating frame + stop pill live exactly as long as the recording does.
                if rec, let screen = self.screenRecorder.activeScreen, let region = self.screenRecorder.activeRegion {
                    self.recIndicator.show(screen: screen, region: region) { [weak self] in
                        self?.toggleScreenRecording()
                    }
                } else {
                    self.recIndicator.hide()
                }
                self.updateStatusIcon()
                self.buildMenu()
            }
            .store(in: &cancellables)
        screenRecorder.onFinished = { [weak self] tempURL, duration in
            guard let self else { return }
            guard let tempURL, let stored = Storage.shared.importVideo(from: tempURL) else {
                if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
                SoundFX.error(); ToastHUD.show(L10n.t("rec.screen.failed"), style: .failure)
                return
            }
            // The recording LIVES in the history (like every other clip): playable, shareable,
            // exportable from its row. Named like meeting notes so the row reads as an event.
            let name = "\(L10n.t("video.name")) — \(Self.meetingDF.string(from: Date()))"
            self.manager.addVideo(fileName: stored, duration: duration, name: name)
            self.panelController.show()   // same "it flew into Klip" reveal as a capture
            let storedURL = Storage.shared.videoURL(for: stored)
            SoundFX.play(.success)
            ToastHUD.show(L10n.t("toast.recSaved.title"), detail: name,
                          actionTitle: L10n.t("toast.recSaved.action")) {
                Task {
                    do {
                        let gif = try await ScreenRecorder.exportGIF(from: storedURL)
                        await MainActor.run {
                            SoundFX.play(.save)
                            ToastHUD.show(L10n.t("toast.gifSaved"), detail: gif.lastPathComponent)
                        }
                    } catch {
                        await MainActor.run {
                            SoundFX.error(); ToastHUD.show(L10n.t("toast.gifFailed"), style: .failure)
                        }
                    }
                }
            }
        }
        // The HUD stays up through "Mixing & transcribing…" and closes when the note is handed off.
        meetingRecorder.$finishing.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] finishing in
                guard let self, !finishing, !self.meetingRecorder.isRecording else { return }
                self.closeMeetingHUD()
            }
            .store(in: &cancellables)
        MeetingRecorder.sweepOrphanedTempFiles()   // clear unfinalized tracks from a crashed run
        manager.start()
        SoundFX.activate()   // copy tick for every pasteboard write made through the app
        ToastHUD.activateAnnouncements()   // …and its VoiceOver equivalent
        // Zero-real-estate copy confirmation (Shottr-style): flash the menu-bar icon to a checkmark
        // whenever anything lands on the pasteboard through Klip.
        NotificationCenter.default.addObserver(forName: .klipDidCopy, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flashStatusIcon() }
        }
        setupHotKeys()
        maybeEnableLoginOnce()
        // On-device is the default: warm the model into memory now so the first voice note doesn't pay
        // the cold pipeline load. This does NOT download — prewarm() bails unless the weights are already
        // on disk, and a first-run download stays lazy on the first voice note (see LocalTranscriber).
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
    /// `finishing` covers the "Mixing & transcribing…" phase, where isRecording is already false.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard meetingRecorder.isRecording || meetingRecorder.finishing else { return .terminateNow }
        Task { @MainActor in
            await meetingRecorder.stop()
            // A stop already in flight (auto-stop, HUD button) makes the call above a no-op: wait
            // until the in-flight finalization actually completes before letting the process die.
            while meetingRecorder.finishing { try? await Task.sleep(nanoseconds: 100_000_000) }
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
        // The red recording indicator outranks the copy flash. Without this guard, copying while a
        // meeting records re-arms the 0.8s debounce on every copy — sustained copying would suppress
        // the only signal that the mic is live, indefinitely.
        guard !meetingRecorder.isRecording else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        fadeStatusIcon(button)
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

    /// Cross-fades the next image/tint swap on the status button so the icon changes read as one
    /// element changing state rather than two icons cutting. Reduce Motion keeps the instant swap.
    private func fadeStatusIcon(_ button: NSStatusBarButton) {
        guard !Motion.reduced else { return }
        button.wantsLayer = true
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Motion.state
        button.layer?.add(fade, forKey: kCATransition)
    }

    /// Base status-item icon: the red record symbol while a meeting records, the clipboard otherwise.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        fadeStatusIcon(button)
        if meetingRecorder.isRecording || screenRecorder.isRecording {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recording")?
                .withSymbolConfiguration(cfg)
            button.contentTintColor = .systemRed
        } else {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Klip")?
                .withSymbolConfiguration(cfg)
            button.contentTintColor = nil
        }
    }

    /// Keeps the menu-bar button lit while a Klip surface it owns is open, the way AppKit lights it
    /// for its own menu. Driven by PanelController.
    func setStatusItemHighlighted(_ on: Bool) {
        statusItem?.button?.highlight(on)
    }

    /// Adds an item whose global-shortcut combo renders as a native right-aligned key equivalent
    /// (system gray, like every macOS menu). Combos with no single-key form fall back to the old
    /// title suffix so the shortcut stays discoverable.
    @discardableResult
    private func addShortcutItem(_ menu: NSMenu, title: String, action: Selector, combo: KeyCombo) -> NSMenuItem {
        let eq = combo.menuKeyEquivalent
        let item = menu.addItem(withTitle: eq.isEmpty ? "\(title)   \(combo.displayString)" : title,
                                action: action, keyEquivalent: eq)
        if !eq.isEmpty { item.keyEquivalentModifierMask = combo.cocoaModifiers }
        return item
    }

    private func buildMenu() {
        let menu = NSMenu()
        addShortcutItem(menu, title: L10n.t("menu.show"), action: #selector(showPanel),
                        combo: Settings.shared.combo)
        addShortcutItem(menu, title: L10n.t("rec.record"), action: #selector(startVoice),
                        combo: Settings.shared.voiceCombo)
        let meeting = addShortcutItem(menu, title: meetingMenuTitle(),
                                      action: #selector(toggleMeetingRecording),
                                      combo: Settings.shared.meetingCombo)
        meetingItem = meeting
        addShortcutItem(menu, title: L10n.t("menu.capture"), action: #selector(startCapture),
                        combo: Settings.shared.captureCombo)
        addShortcutItem(menu, title: L10n.t("menu.captureText"), action: #selector(startTextCapture),
                        combo: Settings.shared.textCaptureCombo)
        addShortcutItem(menu, title: L10n.t(screenRecorder.isRecording ? "menu.recordScreen.stop" : "menu.recordScreen"),
                        action: #selector(toggleScreenRecording), combo: Settings.shared.screenRecCombo)
        if !screenRecorder.isRecording {
            menu.addItem(withTitle: L10n.t("menu.recordScreenFull"), action: #selector(recordFullScreen), keyEquivalent: "")
        }
        addShortcutItem(menu, title: L10n.t("menu.scrollCapture"), action: #selector(startScrollCapture),
                        combo: Settings.shared.scrollCombo)
        addShortcutItem(menu, title: L10n.t("act.upload"), action: #selector(startUpload),
                        combo: Settings.shared.uploadCombo)
        menu.addItem(.separator())
        let recents = NSMenuItem(title: L10n.t("menu.recents"), action: nil, keyEquivalent: "")
        // A FRESH menu each rebuild: an NSMenu can be the submenu of exactly one item, and the menu
        // built on the previous call is still alive (statusItem.menu holds it until the end of this
        // method). Re-attaching one shared instance throws NSInternalInconsistencyException — which
        // AppKit swallows at the top level, silently truncating whatever called us.
        // Safe because a rebuild never lands while a menu is open: every caller reaches us via
        // RunLoop.main or the main queue, both starved during NSEventTrackingRunLoopMode. Schedule one
        // in .common modes and the OPEN Recents submenu is orphaned — menuNeedsUpdate's identity check
        // below rejects it and it silently populates nothing.
        recentsMenu = NSMenu()
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

    /// (Re)creates the Carbon registration for one shortcut. A refused combo leaves the entry absent,
    /// which is what every "is it dead?" check reads.
    private func make(_ kind: ShortcutKind, _ c: KeyCombo) {
        hotKeys[kind] = HotKey(keyCode: c.keyCode, modifiers: c.carbonModifiers, id: kind.carbonID) { [weak self] in
            self?.perform(kind)
        }
    }

    private func perform(_ kind: ShortcutKind) {
        switch kind {
        case .panel:       panelController.toggle()
        case .voice:       panelController.toggleVoiceRecording()
        case .capture:     snapController.start()
        case .upload:      panelController.uploadAudio()
        case .textCapture: snapController.startTextCapture()
        case .meeting:     toggleMeetingRecording()
        case .screenRec:   toggleScreenRecording()
        case .scroll:      startScrollCapture()
        }
    }

    /// Records the ENTIRE display under the cursor — no region selection. Same engine, full frame.
    @objc private func recordFullScreen() {
        guard !screenRecorder.isRecording, !screenRecorder.isStarting, recOverlay == nil else { return }
        guard ScreenCapturer.hasPermission() else { snapController.promptForPermission(); return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }
        screenRecorder.begin(screen: screen,
                             region: CGRect(origin: .zero, size: screen.frame.size))
    }

    /// Scrolling capture: pick the CONTENT region (avoid sticky headers/scrollbars), scroll the
    /// target app yourself, press Done — one long stitched image lands in history + clipboard.
    @objc private func startScrollCapture() {
        // Second ⌥⇧S while a session runs = "finish now with what you have".
        if let live = scrollCapture, live.isActive { live.finishNow(); return }
        guard scrollCapture == nil, scrollOverlay == nil, recOverlay == nil else { return }
        guard ScreenCapturer.hasPermission() else { snapController.promptForPermission(); return }
        let mouse = NSEvent.mouseLocation
        Task { @MainActor in
            do {
                let shot = try await ScreenCapturer.captureDisplay(containing: mouse)
                guard self.scrollOverlay == nil, self.scrollCapture == nil else { return }   // re-check after the await
                let overlay = CaptureOverlayController(shot: shot) { [weak self] screen, region in
                    guard let self else { return }
                    self.scrollOverlay = nil
                    guard let region else { return }   // Esc / empty drag = cancelled
                    let ctrl = ScrollCaptureController(screen: screen, region: region) { [weak self] image, failure in
                        guard let self else { return }
                        self.scrollCapture = nil
                        self.scrollEscHotKey = nil   // release the session-scoped Esc
                        self.scrollIndicator.hide()
                        if let image {
                            self.manager.addAnnotatedScreenshot(image, copyToClipboard: true)
                            // Toast only — a scrolling capture is a separate errand from browsing
                            // the history, and popping the panel over the page you just captured
                            // is the interruption this flow exists to avoid.
                            SoundFX.play(.success)
                            ToastHUD.show(L10n.t("toast.copied"))
                            return
                        }
                        // A nil failure here means the user cancelled: stay silent, like the overlay.
                        if case .failed = failure {
                            SoundFX.error(); ToastHUD.show(L10n.t("capture.failed"), style: .failure)
                        }
                    }
                    self.scrollCapture = ctrl
                    // Same floating frame the recorder uses, in the accent color: marks WHAT is being
                    // captured while Klip scrolls the page itself.
                    self.scrollIndicator.showFrame(screen: screen, region: region)
                    // Esc cancels from ANY app while the session runs; released in the callback above.
                    self.scrollEscHotKey = HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, id: 9) { [weak self] in
                        self?.scrollCapture?.cancel()
                    }
                    ctrl.start()
                }
                self.scrollOverlay = overlay
                overlay.present()
            } catch {
                SoundFX.error(); ToastHUD.show(L10n.t("capture.failed"), style: .failure)
            }
        }
    }

    /// Screen recording: same hotkey toggles start (region selection) and stop. The selection
    /// reuses the capture overlay in region mode; recording starts the moment the region is chosen.
    @objc private func toggleScreenRecording() {
        // isStarting counts as recording: the stream spin-up takes a few hundred ms, and a stop
        // press in that window must stop the recording, not open a second picker over it.
        if screenRecorder.isRecording || screenRecorder.isStarting {
            Task { @MainActor in await screenRecorder.stop() }
            return
        }
        guard recOverlay == nil else { return }   // selection already on screen
        guard ScreenCapturer.hasPermission() else { snapController.promptForPermission(); return }
        let mouse = NSEvent.mouseLocation
        Task { @MainActor in
            do {
                let shot = try await ScreenCapturer.captureDisplay(containing: mouse)
                // Re-check AFTER the await: a second ⌥⇧V during the capture latency passes the
                // synchronous guard above, and overwriting recOverlay would leak the first shield
                // window on screen, undismissable (SnapController documents this exact trap).
                guard self.recOverlay == nil, !self.screenRecorder.isRecording,
                      !self.screenRecorder.isStarting else { return }
                let overlay = CaptureOverlayController(shot: shot) { [weak self] screen, region in
                    guard let self else { return }
                    self.recOverlay = nil
                    guard let region else { return }   // Esc / empty drag = cancelled
                    self.screenRecorder.begin(screen: screen, region: region)
                }
                self.recOverlay = overlay
                overlay.present()
            } catch {
                SoundFX.error(); ToastHUD.show(L10n.t("capture.failed"), style: .failure)
            }
        }
    }

    /// Adopts `combo` as the shortcut's persisted value (and its revert target).
    private func commit(_ kind: ShortcutKind, _ combo: KeyCombo) {
        Settings.shared[keyPath: kind.combo] = combo
        lastGood[kind] = combo
    }

    /// After moving a LIVE shortcut, make sure it actually registered; if the OS rejected the combo (another
    /// app owns it) fall through to the first registerable suggestion, so dedup never persists a dead combo.
    private func ensureLiveRegistered(_ kind: ShortcutKind, avoiding taken: [KeyCombo]) {
        guard hotKeys[kind] == nil else { return }
        for cand in KeyCombo.suggestions where !taken.contains(cand) {
            make(kind, cand)
            if hotKeys[kind] != nil { commit(kind, cand); return }
        }
    }

    /// A migration (or a manual edit) can leave two of the shortcuts on the SAME combo. Carbon rejects a
    /// same-process duplicate registration (eventHotKeyExistsErr), which would leave the later shortcut dead.
    /// Break duplicates before registering: keep the panel combo, move the others off any clash to a free
    /// suggestion (or default).
    private func deduplicateShortcuts() {
        let s = Settings.shared
        // The panel comes first in allCases and so is never the one moved: it keeps its combo and every
        // later kind is compared against the (already fixed) combos of the ones before it.
        var taken: [KeyCombo] = []
        for kind in ShortcutKind.allCases {
            defer { taken.append(s[keyPath: kind.combo]) }
            guard taken.contains(s[keyPath: kind.combo]) else { continue }
            let fixed = taken.contains(kind.defaultCombo)
                ? (KeyCombo.suggestions.first { !taken.contains($0) } ?? kind.defaultCombo)
                : kind.defaultCombo
            commit(kind, fixed)
            // Re-register only when already live (i.e. when called AGAIN after startup recovery) — on the
            // first call the make() loop right after handles registration.
            if hotKeys[kind] != nil {
                make(kind, fixed)
                ensureLiveRegistered(kind, avoiding: taken)
            }
        }
    }

    private func setupHotKeys() {
        deduplicateShortcuts()
        for kind in ShortcutKind.allCases { make(kind, Settings.shared[keyPath: kind.combo]) }
        // If a persisted combination collides with another at startup (HotKey.init returns nil), the
        // shortcut would stay dead for the whole session. Recover with its default shortcut so it isn't lost,
        // then — for everything but panel/voice — with the first free suggestion, quietly.
        var taken: [KeyCombo] = []
        for kind in ShortcutKind.allCases {
            defer { taken.append(Settings.shared[keyPath: kind.combo]) }
            if hotKeys[kind] == nil, Settings.shared[keyPath: kind.combo] != kind.defaultCombo {
                commit(kind, kind.defaultCombo)
                make(kind, kind.defaultCombo)
            }
            guard kind.recoversViaSuggestions, hotKeys[kind] == nil else { continue }
            for s in KeyCombo.suggestions where !taken.contains(s) {
                make(kind, s)
                guard hotKeys[kind] != nil else { continue }
                commit(kind, s)
                // Capture is the one remap worth interrupting for — it has no obvious menu-bar twin in the
                // user's head. Defer the modal: a synchronous runModal here would stall the rest of launch.
                if kind == .capture {
                    Task { @MainActor in self.showAlert(L10n.t("hotkey.capture.changed.title"), L10n.t("hotkey.capture.changed.info")) }
                }
                break
            }
        }
        // The suggestion-recovery loops above can land one shortcut on a sibling's combo (they don't all
        // exclude every sibling). Run dedup once more — now it re-registers what it moves — so no two
        // shortcuts share a combo (which would fire two actions on one keypress).
        deduplicateShortcuts()
        // Dedup may have just freed a combo a still-dead shortcut lost to a SIBLING earlier (Carbon
        // rejects a same-process duplicate registration): retry each dead hotkey with its now-deduped
        // combo before concluding another app owns it.
        for kind in ShortcutKind.allCases where hotKeys[kind] == nil {
            make(kind, Settings.shared[keyPath: kind.combo])
        }
        // If the panel/voice shortcuts are STILL dead after all recovery (another app globally owns even
        // the default combo), tell the user instead of leaving a silently-inert shortcut (deferred so it
        // doesn't block launch).
        if hotKeys[.panel] == nil || hotKeys[.voice] == nil {
            // Here the combo is owned by ANOTHER app, not by a Klip shortcut → dedicated wording.
            Task { @MainActor in SoundFX.error(); self.showAlert(L10n.t("hotkey.dead.title"), L10n.t("hotkey.dead.info")) }
        }
        // Reflect any startup remaps in the menu's shortcut labels.
        buildMenu()
    }

    /// Catch a combo already used by another of OUR shortcuts before touching Carbon: pre-empting the
    /// registration keeps the sibling's hotkey intact and shows the right "in use" wording.
    private func collidesWithOtherShortcut(_ combo: KeyCombo, _ kind: ShortcutKind) -> Bool {
        ShortcutKind.allCases.contains { $0 != kind && Settings.shared[keyPath: $0.combo] == combo }
    }

    /// Moves one shortcut onto `combo`. Two ways it can fail, same outcome: another Klip shortcut
    /// already holds it (caught before touching Carbon), or the OS refuses the registration.
    private func apply(_ kind: ShortcutKind, _ combo: KeyCombo) {
        func revert() {
            SoundFX.error(); ToastHUD.show(L10n.t("hotkey.inuse"), style: .failure)
            Settings.shared[keyPath: kind.combo] = lastGood[kind] ?? kind.defaultCombo
        }
        if collidesWithOtherShortcut(combo, kind) { revert(); buildMenu(); return }
        let ok: Bool
        if let live = hotKeys[kind] { ok = live.reRegister(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) }
        else { make(kind, combo); ok = (hotKeys[kind] != nil) }   // was dead: re-create
        if ok { lastGood[kind] = combo } else { revert() }
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
            // Native menus use template symbol images, never emoji in titles.
            let symbol = it.isVoiceNote == true ? "mic.fill"
                : (it.kind == .image ? "photo" : (it.kind == .video ? "video" : (it.isCredential == true ? "key.fill" : nil)))
            let body: String
            if let nm = it.name, !nm.isEmpty { body = String(nm.prefix(45)) }   // name set by the user
            else if it.isCredential == true { body = CredentialDetector.masked(it.text ?? "") }
            else if it.isVoiceNote == true {
                // transcribed text; if there's none yet, use the preview stripped of its 🎙 prefix
                // (the symbol image already marks it as a voice note).
                let tx = (it.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                body = tx.isEmpty ? String(it.preview.drop(while: { $0 == "🎙" || $0 == " " }).prefix(45))
                                  : String(tx.prefix(45))
            }
            else { body = String(it.preview.prefix(45)) }
            let mi = NSMenuItem(title: "\(Self.recentsDF.string(from: it.createdAt))   \(body)",
                                action: #selector(pasteRecent(_:)), keyEquivalent: "")
            if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            // A recording shows its poster frame instead of the generic glyph — instantly readable
            // as "that video". Cache-only here (menu building is sync); a miss kicks generation so
            // the NEXT open has it.
            if it.kind == .video, let fn = it.videoFileName {
                if let thumb = Storage.shared.cachedVideoThumbnail(fileName: fn) {
                    let sized = NSImage(size: NSSize(width: 34, height: 22))
                    sized.lockFocus()
                    thumb.draw(in: NSRect(x: 0, y: 0, width: 34, height: 22),
                               from: .zero, operation: .sourceOver, fraction: 1)
                    sized.unlockFocus()
                    mi.image = sized
                } else {
                    Task.detached(priority: .utility) { _ = await Storage.shared.generateVideoThumbnail(fileName: fn) }
                }
            }
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
        // Nothing written (e.g. the image's file is gone): don't fall through to ⌘V, which would paste
        // whatever stale content was already on the clipboard. Same guard as PanelController.pick.
        guard manager.copyToPasteboard(item) else { SoundFX.error(); return }
        // Auto-paste like the panel does. No target: the menu closing already restored focus to the
        // previous app, so just send ⌘V. Never auto-paste credentials — same policy as PanelController.pick.
        if item.isCredential != true, Settings.shared.autoPaste, Paster.hasAccessibilityPermission {
            Paster.paste(into: nil)
        }
    }

    private func meetingMenuTitle() -> String {
        // The shortcut renders as the item's key equivalent (see addShortcutItem); only the live
        // elapsed time belongs in the title while recording.
        meetingRecorder.isRecording
            ? "\(L10n.t("meeting.stop"))   \(Self.mmss(meetingRecorder.elapsed))"
            : L10n.t("meeting.record")
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
                },
                onToggleCompact: { [weak self] compact in self?.resizeMeetingHUD(compact: compact) })
            // Borderless floating pill: translucent HUD material, rounded, draggable anywhere,
            // and it remembers where you left it (per user request: a real floating popup).
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 264, height: 150),
                                styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            // Apple's panel recipe (backdrop + ceiling tint + rim), shared with the main panel.
            let fx = GlassPanelView(frame: NSRect(x: 0, y: 0, width: 264, height: 150), radius: 12)
            fx.setContent(NSHostingView(rootView: view))
            panel.contentView = fx
            // Remember wherever the user drags it (restored on the next meeting).
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                                   object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let hud = self.meetingHUD, hud.isVisible, !self.hudResizing else { return }
                    UserDefaults.standard.set(NSStringFromPoint(hud.frame.origin), forKey: "meetingHUDOrigin")
                }
            }
            meetingHUD = panel
        }
        guard let panel = meetingHUD else { return }
        // Fixed size: NSHostingView's fittingSize is 0 before its first layout pass, which made the
        // panel invisible. The SwiftUI content is a fixed 264pt-wide card; height fits all states.
        panel.setContentSize(Self.hudExpandedSize)
        // Restore the user's dragged position, clamping the EXPANDED frame fully into the screen it
        // best lands on (the saved origin can be a compact-pill origin, or reference an unplugged
        // display, which would otherwise leave the card mostly off-screen); default: top-right.
        var restored = false
        if let saved = UserDefaults.standard.string(forKey: "meetingHUDOrigin").map(NSPointFromString) {
            let frame = NSRect(origin: saved, size: Self.hudExpandedSize)
            let best = NSScreen.screens.max { a, b in
                let ia = a.visibleFrame.intersection(frame), ib = b.visibleFrame.intersection(frame)
                return ia.width * ia.height < ib.width * ib.height
            }
            if let v = best?.visibleFrame, !v.intersection(frame).isEmpty {
                panel.setFrameOrigin(NSPoint(x: min(max(saved.x, v.minX), v.maxX - frame.width),
                                             y: min(max(saved.y, v.minY), v.maxY - frame.height)))
                restored = true
            }
        }
        if !restored, let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - panel.frame.width - 16, y: f.maxY - 12))
        }
        let appearing = !panel.isVisible
        hudFadingOut = false   // cancel a close fade in flight: its completion must not order us out
        // Slide down from the screen edge + fade on first appearance (same motion as ToastHUD).
        let target = panel.frame
        if appearing {
            panel.alphaValue = 0
            if !Motion.reduced {
                panel.setFrameOrigin(NSPoint(x: target.origin.x, y: target.origin.y + 8))
            }
        }
        panel.orderFrontRegardless()
        if panel.alphaValue < 1 {   // newly appearing OR caught mid fade-out: fade up to full
            Motion.run(Motion.appear) { _ in
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    /// True while the HUD's close fade-out runs (still visible but going away).
    private var hudFadingOut = false
    /// True during a programmatic compact/expand resize (so didMove doesn't save a transient origin).
    private var hudResizing = false
    private static let hudExpandedSize = NSSize(width: 264, height: 190)
    private static let hudCompactSize = NSSize(width: 178, height: 34)

    /// Resizes the HUD between the full card and the compact pill, keeping its TOP-RIGHT corner
    /// anchored so the collapse feels like the card folding into itself.
    private func resizeMeetingHUD(compact: Bool) {
        guard let panel = meetingHUD else { return }
        let size = compact ? Self.hudCompactSize : Self.hudExpandedSize
        let topRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        hudResizing = true
        Motion.run(Motion.morph, { _ in
            panel.animator().setFrame(NSRect(x: topRight.x - size.width, y: topRight.y - size.height,
                                             width: size.width, height: size.height), display: true)
        }, completion: { [weak self] in
            Task { @MainActor in self?.hudResizing = false }
        })
    }
    private func closeMeetingHUD() {
        guard let hud = meetingHUD, hud.isVisible, !hudFadingOut else { return }
        hudFadingOut = true
        Motion.run(Motion.dismiss, { _ in
            hud.animator().alphaValue = 0
        }, completion: { [weak self] in
            MainActor.assumeIsolated {   // AppKit animation completions run on the main thread
                guard let self, self.hudFadingOut else { return }   // re-shown mid-fade: leave it up
                self.hudFadingOut = false
                hud.orderOut(nil)
                hud.alphaValue = 1   // ready for the next appearance
            }
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
                onHotKeyChange: { [weak self] kind, combo in self?.apply(kind, combo) },
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
            ToastHUD.show(L10n.t("autopaste.enabled.title"))
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
        // Direct write to ~/Downloads, no save panel — same naming as every other export.
        // exportBackup deletes an existing destination, so the name genuinely must be free.
        let url = Storage.uniqueDownloadsURL(base: "Klip backup \(Storage.exportTimestamp)", ext: "zip")
        manager.pauseMonitoring()   // keep the poll from adding/trimming media mid-copy (it would corrupt the zip)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in   // ditto + heavy copy: off the main thread
            do {
                try Storage.shared.exportBackup(to: url)
                DispatchQueue.main.async {
                    self?.manager.resumeMonitoring()
                    ToastHUD.show(L10n.t("toast.backupSaved"), detail: url.lastPathComponent, actionTitle: L10n.t("toast.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showAlert(L10n.t("export.fail"), error.localizedDescription)
                    self?.manager.resumeMonitoring()
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

import AppKit
import SwiftUI

/// Standard (titled) Preferences window, distinct from the floating panel.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    convenience init(onHotKeyChange: @escaping (KeyCombo) -> Void,
                     onVoiceHotKeyChange: @escaping (KeyCombo) -> Void,
                     onCaptureHotKeyChange: @escaping (KeyCombo) -> Void,
                     onUploadHotKeyChange: @escaping (KeyCombo) -> Void,
                     onTextCaptureHotKeyChange: @escaping (KeyCombo) -> Void,
                     onMeetingHotKeyChange: @escaping (KeyCombo) -> Void,
                     onScreenRecHotKeyChange: @escaping (KeyCombo) -> Void,
                     onScrollHotKeyChange: @escaping (KeyCombo) -> Void,
                     onMaxItemsChange: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = L10n.t("win.prefs")
        window.isReleasedWhenClosed = false
        Glass.install(PreferencesView(onHotKeyChange: onHotKeyChange,
                                      onVoiceHotKeyChange: onVoiceHotKeyChange,
                                      onCaptureHotKeyChange: onCaptureHotKeyChange,
                                      onUploadHotKeyChange: onUploadHotKeyChange,
                                      onTextCaptureHotKeyChange: onTextCaptureHotKeyChange,
                                      onMeetingHotKeyChange: onMeetingHotKeyChange,
                                      onScreenRecHotKeyChange: onScreenRecHotKeyChange,
                                      onScrollHotKeyChange: onScrollHotKeyChange,
                                      onMaxItemsChange: onMaxItemsChange), in: window)
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    func show() {
        // Switch to a "regular" app while the window is open: guarantees keyboard focus
        // (needed to type/paste the API key into the SecureField).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar app (no Dock) — but only if we weren't launched as a regular app
        // (KLIP_REGULAR), otherwise closing Preferences would wrongly strip the Dock icon.
        if ProcessInfo.processInfo.environment["KLIP_REGULAR"] == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

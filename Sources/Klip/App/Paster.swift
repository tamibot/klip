import AppKit
import ApplicationServices   // AXIsProcessTrusted, kAXTrustedCheckOptionPrompt
import CoreGraphics          // CGEvent, CGEventSource

/// Reactivates the previous app and synthesizes ⌘V to automatically paste the chosen item.
/// Requires Accessibility permission; if missing, it degrades to just returning focus (the content
/// is already on the pasteboard and the user pastes manually).
enum Paster {

    private static let keyCodeV: CGKeyCode = 9          // kVK_ANSI_V (physical position, valid for ⌘V)
    private static let activationDelay: TimeInterval = 0.13

    /// Silent check (no dialog). Used to decide auto-paste vs fallback.
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Check that OPENS the system dialog if permission isn't granted yet.
    /// Only call this under explicit user action.
    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Reactivates `target` and, if permitted, synthesizes ⌘V after a brief delay.
    /// The content must already be on the pasteboard BEFORE calling.
    /// - Returns: true if auto-paste was attempted; false if it fell back (copy-only).
    @discardableResult
    static func paste(into target: NSRunningApplication?) -> Bool {
        target?.activate()

        guard hasAccessibilityPermission else { return false }

        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV()
        }
        return true
    }

    private static func postCommandV() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCodeV, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCodeV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

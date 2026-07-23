import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Field that records a key combination for the global shortcut.
struct KeyRecorderView: NSViewRepresentable {
    @Binding var combo: KeyCombo
    var onChange: (KeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let v = RecorderNSView()
        v.current = combo
        v.onCapture = { newCombo in
            combo = newCombo
            onChange(newCombo)
        }
        return v
    }

    func updateNSView(_ v: RecorderNSView, context: Context) {
        v.current = combo
    }
}

final class RecorderNSView: NSView {
    var onCapture: ((KeyCombo) -> Void)?
    var current = KeyCombo.defaultCombo { didSet { needsDisplay = true } }
    private var recording = false { didSet { needsDisplay = true } }

    // Losing focus (clicking another control / another recorder taking first responder) must exit
    // the "type shortcut…" state — otherwise the field looks armed while keys go nowhere.
    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording.toggle()
        window?.makeFirstResponder(recording ? self : nil)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; return }   // Esc cancels
        let carbon = cocoaToCarbonModifiers(
            event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        let candidate = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
        // Requires a non-Shift modifier: a Shift-only combo would register globally and hijack
        // shifted letters (typing capital E) system-wide.
        guard candidate.isValid, carbon & ~UInt32(shiftKey) != 0 else {
            MainActor.assumeIsolated { SoundFX.warning() }   // key events are always on the main thread
            return
        }
        current = candidate
        recording = false
        onCapture?(candidate)
    }

    override func flagsChanged(with event: NSEvent) {
        if recording { needsDisplay = true }
    }

    override func draw(_ rect: NSRect) {
        // Armed = the same selection language as the filter chips: a SOLID accent fill with
        // white, semibold content. Idle = a faint neutral pill.
        let bg = recording ? NSColor.controlAccentColor
                           : NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        bg.setFill(); path.fill()

        let label = recording ? L10n.t("hotkey.record.prompt") : current.displayString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: recording ? .semibold : .medium),
            .foregroundColor: recording ? NSColor.white : NSColor.labelColor
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2,
                            y: (bounds.height - size.height) / 2)
        (label as NSString).draw(at: point, withAttributes: attrs)
    }
}

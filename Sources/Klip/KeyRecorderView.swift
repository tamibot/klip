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
        guard candidate.isValid else { NSSound.beep(); return }  // requires a modifier
        current = candidate
        recording = false
        onCapture?(candidate)
    }

    override func flagsChanged(with event: NSEvent) {
        if recording { needsDisplay = true }
    }

    override func draw(_ rect: NSRect) {
        let bg = recording ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                           : NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        bg.setFill(); path.fill()

        let label = recording ? L10n.t("hotkey.record.prompt") : current.displayString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2,
                            y: (bounds.height - size.height) / 2)
        (label as NSString).draw(at: point, withAttributes: attrs)
    }
}

/// Shortcut field with a recorder + a menu of suggested combinations.
struct HotKeyField: View {
    @Binding var combo: KeyCombo
    var onChange: (KeyCombo) -> Void

    var body: some View {
        HStack(spacing: 6) {
            KeyRecorderView(combo: $combo, onChange: onChange)
                .frame(width: 150, height: 28)
            Menu {
                ForEach(Array(KeyCombo.suggestions.enumerated()), id: \.offset) { _, c in
                    Button(c.displayString) { combo = c; onChange(c) }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help(L10n.t("hotkey.suggestions"))
        }
    }
}

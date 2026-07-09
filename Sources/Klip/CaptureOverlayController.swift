import AppKit

/// Shield-level window that CAN become key (unlike a plain borderless NSWindow, which by default
/// never receives keyboard events → Esc would not cancel). Required so keyboard cancellation works
/// while the window sits at the system shield level.
private final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Borderless full-screen window that shows the frozen, dimmed capture and lets
/// the user drag out a region. On release, it crops and returns an NSImage of the chosen area.
final class CaptureOverlayController {
    private var window: NSWindow?
    private let shot: DisplayShot
    private let onComplete: (NSImage?) -> Void
    private var resolved = false               // avoids double-dismiss / firing onComplete twice
    private var escMonitor: Any?               // Esc backup while Klip is active (see present() for the limit)

    init(shot: DisplayShot, onComplete: @escaping (NSImage?) -> Void) {
        self.shot = shot
        self.onComplete = onComplete
    }

    func present() {
        let frame = shot.screen.frame
        let win = ShieldWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.ignoresMouseEvents = false
        win.hasShadow = false

        let view = CaptureOverlayView(shot: shot) { [weak self] rectInView in
            self?.finish(selectionInView: rectInView)
        } onCancel: { [weak self] in
            self?.dismiss(nil)
        }
        win.contentView = view
        win.setFrame(frame, display: true)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view)
        self.window = win

        // Esc backup (keyCode 53) for when the contentView isn't first responder but Klip is still active.
        // It's a LOCAL monitor, so it can't fire if the overlay never became active at all — in that case a
        // single click (mouseUp with no drag → onCancel) is the way out, not Esc.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(nil); return nil }
            return event
        }
    }

    /// Converts the selection (points, bottom-left origin of the view) to bitmap pixels
    /// (top-left origin) and crops the CGImage.
    private func finish(selectionInView rect: NSRect) {
        guard !resolved else { return }
        guard rect.width >= 4, rect.height >= 4 else { dismiss(nil); return }
        let scale = shot.scale
        let viewH = shot.screen.frame.height
        let imgBounds = CGRect(x: 0, y: 0, width: shot.cgImage.width, height: shot.cgImage.height)
        let px = CGRect(
            x: rect.minX * scale,
            y: (viewH - rect.maxY) * scale,        // flip Y: Cocoa (bottom) → CGImage (top)
            width: rect.width * scale,
            height: rect.height * scale
        ).integral.intersection(imgBounds)         // clamp: a selection at the edge must not exceed the bitmap

        guard !px.isNull, px.width >= 1, px.height >= 1,
              let cropped = shot.cgImage.cropping(to: px) else { dismiss(nil); return }
        let image = NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
        dismiss(image)
    }

    private func dismiss(_ image: NSImage?) {
        guard !resolved else { return }
        resolved = true
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        window?.orderOut(nil)
        window = nil
        onComplete(image)
    }
}

/// View that draws the frozen capture, the dimming, the selection, and the dimensions badge.
private final class CaptureOverlayView: NSView {
    private let shot: DisplayShot
    private let onSelect: (NSRect) -> Void
    private let onCancel: () -> Void

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private let bgImage: NSImage

    init(shot: DisplayShot, onSelect: @escaping (NSRect) -> Void, onCancel: @escaping () -> Void) {
        self.shot = shot
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.bgImage = NSImage(cgImage: shot.cgImage,
                               size: NSSize(width: shot.screen.frame.width, height: shot.screen.frame.height))
        super.init(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        // Background: the frozen capture — kept fully legible (Shottr-style). Blacking the whole
        // screen out made every capture feel like a modal interruption; the crosshair + hint pill
        // already signal the mode.
        bgImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)

        guard currentRect.width > 0, currentRect.height > 0 else {
            drawHint()   // no selection yet: explain what to do
            return
        }

        // Once a drag starts, a SOFT outside dim makes the selection pop without hiding the screen.
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()

        // "Hole": repaint the selected area without dimming.
        bgImage.draw(in: currentRect, from: pixelSourceRect(for: currentRect), operation: .copy, fraction: 1)

        // Selection border.
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: currentRect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1.5
        border.stroke()

        drawDimensionBadge(for: currentRect)
    }

    /// Source rect (in image points, bottom-left origin) corresponding to the view area.
    private func pixelSourceRect(for rect: NSRect) -> NSRect { rect }

    /// Centered hint shown while the user hasn't dragged anything yet (so the overlay is self-explanatory).
    private func drawHint() {
        let text = L10n.t("capture.hint")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 18, padY: CGFloat = 11
        let pill = NSRect(x: bounds.midX - (size.width + padX * 2) / 2,
                          y: bounds.midY - (size.height + padY * 2) / 2,
                          width: size.width + padX * 2, height: size.height + padY * 2)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + padX, y: pill.minY + padY), withAttributes: attrs)
    }

    private func drawDimensionBadge(for rect: NSRect) {
        let wPx = Int(rect.width * shot.scale)
        let hPx = Int(rect.height * shot.scale)
        let label = "\(wPx) × \(hPx)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 6
        var badge = NSRect(x: rect.minX, y: rect.maxY + 6,
                           width: textSize.width + pad * 2, height: textSize.height + pad)
        // If it doesn't fit above, place it inside/below.
        if badge.maxY > bounds.maxY { badge.origin.y = rect.minY - badge.height - 6 }
        if badge.minY < bounds.minY { badge.origin.y = rect.minY + 6 }
        badge.origin.x = max(bounds.minX, min(badge.origin.x, bounds.maxX - badge.width))

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(at: NSPoint(x: badge.minX + pad, y: badge.minY + pad / 2), withAttributes: attrs)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                             width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = currentRect
        startPoint = nil
        if rect.width >= 4, rect.height >= 4 { onSelect(rect) } else { onCancel() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() }   // Esc
        else { super.keyDown(with: event) }
    }

    /// Esc through the standard responder chain (in addition to keyDown and the safety-net monitor).
    override func cancelOperation(_ sender: Any?) { onCancel() }
}
